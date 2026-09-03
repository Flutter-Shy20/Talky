import 'package:drift/drift.dart';

import '../../db/app_database.dart';
import '../../db/chat_dao.dart';
import '../../utils/call_log_preview.dart';
import '../../utils/media_album.dart';
import 'conversation_merge.dart';

/// Source unique de vérité pour l'état dérivé d'une conversation :
/// `lastMessage*`, `lastMessageStatus`, `unreadCount`.
///
/// Après **toute** mutation de la table `messages`, appeler [recompute].
class ConversationSummaryReducer {
  ConversationSummaryReducer(this._db, this._dao);

  final AppDatabase _db;
  final ChatDao _dao;

  /// Recalcule aperçu + unread + statut à partir des messages locaux.
  ///
  /// Fallback : si aucun message local visible, conserve `unreadCount` / aperçu
  /// déjà présents (valeur serveur d'une liste fraîche) sauf si [serverUnread]
  /// est fourni pour initialiser.
  Future<void> recompute(
    int conversID,
    int myId, {
    int? serverUnread,
  }) async {
    if (conversID == 0) return;

    await _db.transaction(() async {
      final conv = await (_db.select(_db.localConversations)
            ..where((c) => c.conversID.equals(conversID)))
          .getSingleOrNull();
      if (conv == null) return;

      final latest = await (_db.select(_db.localMessages)
            ..where((m) =>
                m.conversationID.equals(conversID) &
                (m.deletedForID.isNull() | m.deletedForID.equals(myId).not()))
            ..orderBy([
              (m) =>
                  OrderingTerm(expression: m.sendAt, mode: OrderingMode.desc),
              (m) =>
                  OrderingTerm(expression: m.msgID, mode: OrderingMode.desc),
            ])
            ..limit(1))
          .getSingleOrNull();

      // Aucun message local : fallback serveur / conserver l'existant.
      if (latest == null) {
        if (serverUnread != null && serverUnread != conv.unreadCount) {
          await (_db.update(_db.localConversations)
                ..where((c) => c.conversID.equals(conversID)))
              .write(LocalConversationsCompanion(
            unreadCount: Value(serverUnread),
          ));
        }
        return;
      }

      // Ne pas écraser un envoi optimiste plus récent que le dernier confirmé.
      if (latest.msgID > 0 &&
          await _dao.hasPendingNewerThan(conversID, latest.sendAt)) {
        // Unread toujours dérivé (même pendant pending).
        await _updateCountersOnly(conversID, myId, conv);
        return;
      }

      // Le dernier élément de la conversation n'est pas un message.
      //
      // Un appel n'habite pas `messages` : il vit dans `local_calls`. Ce
      // réducteur, lui, ne connaît que les messages — il prenait donc le dernier
      // message pour le dernier élément et réécrivait l'aperçu par-dessus celui
      // du journal d'appel. Le serveur le reposait à la synchronisation
      // suivante, le réducteur le réécrasait : l'aperçu battait entre « Appel
      // vocal » et le dernier message, indéfiniment.
      //
      // On ne possède l'aperçu que lorsque le message est bien la chose la plus
      // récente. Sinon on ne touche qu'aux compteurs, qui restent dérivés des
      // messages dans tous les cas.
      final journalPlusRecent = isCallLogPreviewType(conv.lastMessageType) &&
          conv.lastMessageAt != null &&
          !conv.lastMessageAt!.isBefore(latest.sendAt);

      if (journalPlusRecent) {
        await _updateCountersOnly(conversID, myId, conv);
        return;
      }

      // L'historique local peut être en retard sur l'aperçu, et le retard ne
      // se voit pas d'ici : `latest` est bien le dernier message *que l'on
      // possède*, pas le dernier message de la conversation.
      //
      // Au premier démarrage après une connexion, le bootstrap de
      // [ConversationSync] remplit `messages` via POST /messages/sync, qui trie
      // par `msgID` CROISSANT : la première page ne rapporte que les messages
      // les plus anciens. Réécrire l'aperçu à partir de ce `latest` faisait
      // reculer `lastMessageAt` de plusieurs mois, et la conversation plongeait
      // au bas d'une liste triée par `lastMessageAt DESC` — la « discussion
      // disparue » que seul un tirer-pour-rafraîchir ramenait, puisque le
      // merge HTTP y réimposait l'aperçu serveur.
      //
      // Un recul n'est légitime que s'il s'explique en local : le message qui
      // portait l'aperçu a été supprimé pour moi, auquel cas il est toujours
      // en base (masqué par le filtre `deletedForID` ci-dessus) et
      // [ChatDao.hasMessageNewerThan] le voit. Sinon c'est un trou
      // d'historique : on laisse l'aperçu tranquille et on ne dérive que les
      // compteurs, eux toujours calculés sur les messages présents.
      final apercuPlusRecentQueLeLocal = conv.lastMessageAt != null &&
          conv.lastMessageAt!.isAfter(latest.sendAt);
      if (apercuPlusRecentQueLeLocal &&
          !await _dao.hasMessageNewerThan(conversID, latest.sendAt)) {
        await _updateCountersOnly(conversID, myId, conv);
        return;
      }

      final mine = myId != 0 && latest.senderID == myId;
      final preview = normalizeConversationPreview(
        latest.isDeleted
            ? ConversationMerge.deletedPreview
            : ConversationMerge.previewForMedia(
                latest.type,
                latest.content,
                latest.mediaName,
                isViewOnce: latest.isViewOnce,
              ),
      );
      final desiredStatus = mine ? latest.status : null;
      final unread = await _dao.countUnread(conversID, myId);
      final mentionne = await _hasUnreadMention(conversID, myId);

      // Aperçu traduit : uniquement pour le texte pur. Pour un média, l'aperçu
      // est un libellé localisé (« 📷 Photo ») que le client redérive déjà —
      // y injecter une légende traduite mélangerait deux registres.
      final translatedPreview =
          latest.type == 0 && !latest.isDeleted ? latest.translatedContent : null;

      final needsUpdate = conv.lastMessageSenderID != latest.senderID ||
          conv.lastMessageType != latest.type ||
          conv.lastMessage != preview ||
          conv.lastMessageTranslated != translatedPreview ||
          conv.lastMessageAt != latest.sendAt ||
          conv.lastMessageStatus != desiredStatus ||
          conv.unreadCount != unread ||
          conv.hasUnreadMention != mentionne;

      if (!needsUpdate) return;

      await (_db.update(_db.localConversations)
            ..where((c) => c.conversID.equals(conversID)))
          .write(LocalConversationsCompanion(
        lastMessage: Value(preview),
        lastMessageTranslated: Value(translatedPreview),
        lastMessageSenderID: Value(latest.senderID),
        lastMessageType: Value(latest.type),
        lastMessageAt: Value(latest.sendAt),
        lastMessageStatus: Value(desiredStatus),
        unreadCount: Value(unread),
        hasUnreadMention: Value(mentionne),
      ));
    });
  }

  /// Ne dérive que les compteurs, sans toucher à l'aperçu : le chemin des trois
  /// cas où le dernier message local n'est pas ce que la conversation doit
  /// afficher (envoi optimiste plus récent, journal d'appel plus récent,
  /// historique local incomplet). Les compteurs, eux, restent dérivés des
  /// messages présents dans tous les cas.
  Future<void> _updateCountersOnly(
    int conversID,
    int myId,
    LocalConversation conv,
  ) async {
    final unread = await _dao.countUnread(conversID, myId);
    final mentionne = await _hasUnreadMention(conversID, myId);
    if (unread == conv.unreadCount && mentionne == conv.hasUnreadMention) {
      return;
    }
    await (_db.update(_db.localConversations)
          ..where((c) => c.conversID.equals(conversID)))
        .write(LocalConversationsCompanion(
      unreadCount: Value(unread),
      hasUnreadMention: Value(mentionne),
    ));
  }

  /// Réutilise la requête du bouton de saut : une seule définition de « mention
  /// non lue », donc pas de dérive entre le compteur du fil et le marqueur de
  /// la liste.
  Future<bool> _hasUnreadMention(int conversID, int myId) async {
    final ids = await _dao.unreadMentionMsgIds(conversID, myId);
    return ids.isNotEmpty;
  }

  Future<void> recomputeAll(int myId) async {
    if (myId == 0) return;
    final convs = await _db.select(_db.localConversations).get();
    for (final conv in convs) {
      await recompute(conv.conversID, myId);
    }
  }

  /// Recalcule uniquement les conversations listées (évite O(n) systématique).
  Future<void> recomputeMany(Set<int> conversIDs, int myId) async {
    if (myId == 0 || conversIDs.isEmpty) return;
    for (final id in conversIDs) {
      if (id == 0) continue;
      await recompute(id, myId);
    }
  }
}
