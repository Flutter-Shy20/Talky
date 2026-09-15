import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/db/chat_dao.dart';
import 'package:talky_flutter/core/services/chat/conversation_summary_reducer.dart';

void main() {
  late AppDatabase db;
  late ChatDao dao;
  late ConversationSummaryReducer reducer;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = ChatDao(db);
    reducer = ConversationSummaryReducer(db, dao);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedConv(
    int id, {
    int unread = 0,
    String? lastMessage,
    DateTime? lastMessageAt,
    int? lastMessageSenderID,
  }) async {
    await db.into(db.localConversations).insert(
          LocalConversationsCompanion.insert(
            conversID: Value(id),
            isGroup: const Value(false),
            unreadCount: Value(unread),
            participantsJson: const Value('[]'),
            lastMessage: Value(lastMessage),
            lastMessageAt: Value(lastMessageAt),
            lastMessageSenderID: Value(lastMessageSenderID),
            lastMessageType: const Value(0),
          ),
        );
  }

  Future<void> seedMsg({
    required int msgID,
    required int conversID,
    required int senderID,
    required String content,
    required DateTime sendAt,
    int? deletedForID,
  }) async {
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          clientId: 'srv_$msgID',
          msgID: Value(msgID),
          conversationID: conversID,
          senderID: senderID,
          content: Value(content),
          sendAt: sendAt,
          status: const Value(1),
          deletedForID: Value(deletedForID),
        ));
  }

  test('recomputeMany ne touche que les IDs listés', () async {
    const myId = 7;
    await seedConv(1, unread: 9);
    await seedConv(2, unread: 9);

    final now = DateTime.now().toUtc();
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          clientId: 'srv_1',
          msgID: const Value(1),
          conversationID: 1,
          senderID: 9,
          content: const Value('hello'),
          sendAt: now,
          status: const Value(1),
        ));

    await reducer.recomputeMany({1}, myId);

    final c1 = await (db.select(db.localConversations)
          ..where((c) => c.conversID.equals(1)))
        .getSingle();
    final c2 = await (db.select(db.localConversations)
          ..where((c) => c.conversID.equals(2)))
        .getSingle();

    expect(c1.lastMessage, 'hello');
    expect(c1.unreadCount, 1);
    expect(c2.unreadCount, 9); // inchangé
  });

  // Régression : au premier démarrage après une connexion, le bootstrap
  // remplit `messages` par msgID croissant — la première page ne rapporte que
  // les plus anciens. Le réducteur réécrivait alors l'aperçu avec ce vieux
  // message : la conversation plongeait au bas de la liste (triée par
  // lastMessageAt DESC) jusqu'au tirer-pour-rafraîchir suivant.
  test('un historique local incomplet ne fait pas reculer l\'aperçu', () async {
    const myId = 7;
    // Date fixe à la seconde : Drift stocke un timestamp epoch en secondes et
    // relit en heure locale — comparer une DateTime.now() milliseconde par
    // milliseconde ne testerait que la sérialisation.
    final maintenant = DateTime.utc(2026, 9, 3, 10, 30);
    final vieux = maintenant.subtract(const Duration(days: 60));

    await seedConv(
      1,
      lastMessage: 'dernier message',
      lastMessageAt: maintenant,
      lastMessageSenderID: 9,
    );
    await seedMsg(
      msgID: 1,
      conversID: 1,
      senderID: 9,
      content: 'tout premier message',
      sendAt: vieux,
    );

    await reducer.recompute(1, myId);

    final c = await (db.select(db.localConversations)
          ..where((c) => c.conversID.equals(1)))
        .getSingle();
    expect(c.lastMessage, 'dernier message');
    expect(c.lastMessageAt!.toUtc(), maintenant);
    // Les compteurs, eux, restent dérivés des messages présents.
    expect(c.unreadCount, 1);
  });

  // Le pendant du test précédent : un recul qui s'explique en local doit bien
  // avoir lieu, sinon un message supprimé pour moi resterait affiché en aperçu.
  test('une suppression pour moi fait bien reculer l\'aperçu', () async {
    const myId = 7;
    // Date fixe à la seconde : Drift stocke un timestamp epoch en secondes et
    // relit en heure locale — comparer une DateTime.now() milliseconde par
    // milliseconde ne testerait que la sérialisation.
    final maintenant = DateTime.utc(2026, 9, 3, 10, 30);
    final avant = maintenant.subtract(const Duration(minutes: 5));

    await seedConv(
      1,
      lastMessage: 'dernier message',
      lastMessageAt: maintenant,
      lastMessageSenderID: 9,
    );
    await seedMsg(
      msgID: 1,
      conversID: 1,
      senderID: 9,
      content: 'celui d\'avant',
      sendAt: avant,
    );
    await seedMsg(
      msgID: 2,
      conversID: 1,
      senderID: 9,
      content: 'dernier message',
      sendAt: maintenant,
      deletedForID: myId,
    );

    await reducer.recompute(1, myId);

    final c = await (db.select(db.localConversations)
          ..where((c) => c.conversID.equals(1)))
        .getSingle();
    expect(c.lastMessage, 'celui d\'avant');
    expect(c.lastMessageAt!.toUtc(), avant);
  });

  test('recomputeMany set vide = no-op', () async {
    await seedConv(1, unread: 3);
    await reducer.recomputeMany({}, 7);
    final c = await (db.select(db.localConversations)
          ..where((c) => c.conversID.equals(1)))
        .getSingle();
    expect(c.unreadCount, 3);
  });
}
