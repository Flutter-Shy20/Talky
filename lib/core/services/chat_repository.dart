import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart' show SecretKey, Sha256;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:mime/mime.dart' show lookupMimeType;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../crypto/e2ee_service.dart';
import '../crypto/group_cipher_service.dart';
import '../crypto/media_cipher_service.dart';
import '../crypto/vault_service.dart';
import '../db/app_database.dart';
import '../db/chat_dao.dart';
import 'media_cache_service.dart';
import '../../talky_api_client.dart';
import '../../talky_models.dart';
class ChatRepository {
  /// Repli affiché quand un déchiffrement échoue (message jamais reçu de
  /// sender key / session, OU tentative de redéchiffrer un message déjà
  /// consommé — Double Ratchet et Sender Keys sont tous deux à usage
  /// unique : une resynchronisation ne peut PAS redéchiffrer un message déjà
  /// vu). Traité comme équivalent à "pas de contenu" dans `_upsertServerMsg`
  /// pour ne jamais régresser un contenu déjà bien déchiffré une 1ère fois.
  static const _kEncryptedFallback = '[🔒 Message chiffré]';

  final AppDatabase _db;
  final ChatDao _dao;
  final TalkyApiClient _api;
  final E2eeService _e2ee;
  final GroupCipherService _group;
  final VaultService _vault;
  final MediaCacheService _mediaCache = MediaCacheService();
  final MediaCipherService _mediaCipher = MediaCipherService();

  int _myId = 0;
  bool _listenersBound = false;

  /// Conversation actuellement ouverte à l'écran (0 = aucune). Un message reçu
  /// pour cette conversation est marqué lu immédiatement et n'incrémente pas
  /// l'unread (l'utilisateur le voit en direct).
  int _activeConversationID = 0;

  /// Lectures à confirmer au serveur dès la reconnexion (lecture hors-ligne).
  final Set<int> _pendingReads = {};
  /// Retry tracker pour les lectures hors-ligne (conversationID -> retryCount)
  final Map<int, int> _pendingReadsRetry = {};

  /// `clientId` des envois média en cours (chiffrement + upload, avant
  /// `_emitSend`). Un média volumineux peut prendre plusieurs secondes ;
  /// si une reconnexion déclenche `flushOutbox` pendant ce laps de temps, la
  /// ligne encore `syncPending` serait reprise en parallèle et émise deux
  /// fois (le serveur ne déduplique pas par clientId). Ce set empêche
  /// `flushOutbox` de retraiter une ligne déjà en cours d'envoi.
  final Set<String> _sendsInFlight = {};

  void setActiveConversation(int conversationID) =>
      _activeConversationID = conversationID;
  void clearActiveConversation(int conversationID) {
    if (_activeConversationID == conversationID) _activeConversationID = 0;
  }

  ChatRepository._(this._api, this._db, this._e2ee, this._group, this._vault)
      : _dao = ChatDao(_db);

  MediaCacheService get mediaCache => _mediaCache;
  E2eeService get e2ee => _e2ee;
  GroupCipherService get group => _group;
  VaultService get vault => _vault;

  factory ChatRepository({
    required TalkyApiClient api,
    AppDatabase? database,
    E2eeService? e2ee,
    GroupCipherService? group,
    VaultService? vault,
  }) {
    final db = database ?? AppDatabase();
    final resolvedE2ee = e2ee ?? E2eeService(api, db: db);
    return ChatRepository._(
      api, db,
      resolvedE2ee,
      group ?? GroupCipherService(api, resolvedE2ee, db: db),
      vault ?? VaultService(),
    );
  }

  AppDatabase get db => _db;
  ChatDao get dao => _dao;
  int get myId => _myId;
  Stream<List<LocalConversation>> watchConversations() => _dao.watchConversations();
  Stream<LocalConversation?> watchConversation(int conversationID) =>
      _dao.watchConversation(conversationID);
  Stream<List<LocalMessage>> watchMessages(int conversationID) =>
      _dao.watchMessages(conversationID, _myId);
 
  /// Handler `auth:verified`. Méthode (et non lambda stockée) pour garder
  /// une référence stable utilisable par `removeSocketListener` au logout.
  Future<void> _onAuthVerified(dynamic _) async {
    try {
      rejoinActiveRoom();
      await resyncActiveConversation();
      await _flushPendingReads();
      // Rejoue tout message resté `syncPending` dès la reconnexion, au lieu
      // d'attendre le prochain tick de `ChatSyncTimer` (jusqu'à 5 min) : sur
      // réseau mobile réel, un `message:sent` perdu lors d'une coupure socket
      // ne doit pas laisser l'expéditeur bloqué sur "en cours" plus longtemps
      // que nécessaire. Sûr désormais grâce à la dédup serveur par clientId
      // (migration 013) : un message déjà bien arrivé n'est jamais dupliqué.
      await flushOutbox();
    } catch (e) {
      debugPrint('[ChatRepo] authVerified handler failed: $e');
    }
  }

  Future<void> bind(int myId) async {
    if (myId == 0) return;
    _myId = myId;

    // Purges et éviction attendues au démarrage pour stabiliser la DB.
    await _dao.purgeGhostMessages();
    await _dao.purgeDuplicateOptimistics();
    await _dao.purgeDuplicateByMsgId();
    await _mediaCache.evictIfNeeded();

    // Initialise E2EE : charge/génère la paire de clés et uploade la clé publique.
    await _e2ee.init(myId);
    _group.init(myId);

    // Coffre : tenter de restaurer la clé depuis le secure storage.
    await _vault.tryLoad(myId);

    if (_listenersBound) return;
    _listenersBound = true;

    _api.onSocketEvent(SocketEvents.messageReceived, _onMessageReceived);
    _api.onSocketEvent(SocketEvents.messageSent, _onMessageSent);
    _api.onSocketEvent(SocketEvents.messageUpdated, _onMessageUpdated);
    _api.onSocketEvent(SocketEvents.messageDeleted, _onMessageDeleted);
    _api.onSocketEvent(SocketEvents.messageStatus, _onMessageStatus);
    _api.onSocketEvent(SocketEvents.conversationCreated, _onConversationCreated);
    _api.onSocketEvent(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);
    _api.onSocketEvent(SocketEvents.groupKeyDistribution, _onGroupKeyDistribution);
    _api.onSocketEvent(SocketEvents.authVerified, _onAuthVerified);
  }

  /// Détache les listeners socket et autorise un futur `bind` (cas logout/login
  /// dans la même session d'app). `disconnectSocket` aurait déjà vidé le
  /// registre côté API client, mais on remet le drapeau à zéro pour que la
  /// prochaine connexion repasse par l'enregistrement complet.
  void unbind() {
    if (!_listenersBound) return;
    _listenersBound = false;
    _api.removeSocketListener(SocketEvents.messageReceived, _onMessageReceived);
    _api.removeSocketListener(SocketEvents.messageSent, _onMessageSent);
    _api.removeSocketListener(SocketEvents.messageUpdated, _onMessageUpdated);
    _api.removeSocketListener(SocketEvents.messageDeleted, _onMessageDeleted);
    _api.removeSocketListener(SocketEvents.messageStatus, _onMessageStatus);
    _api.removeSocketListener(SocketEvents.conversationCreated, _onConversationCreated);
    _api.removeSocketListener(SocketEvents.groupMemberRemoved, _onGroupMemberRemoved);
    _api.removeSocketListener(SocketEvents.groupKeyDistribution, _onGroupKeyDistribution);
    _api.removeSocketListener(SocketEvents.authVerified, _onAuthVerified);
    _activeConversationID = 0;
    _pendingReads.clear();
    _pendingReadsRetry.clear();
    _myId = 0;
    _e2ee.clear();
    _vault.lock();
  }

  void _onConversationCreated(dynamic data) {
    if (data is! Map) return;
    final json = Map<String, dynamic>.from(data);
    final conv = Conversation.fromJson(json);
    _dao.upsertConversation(_convToCompanion(conv, json));

    // Groupe (création ou nouveau membre ajouté) : (re)génère ma sender key si
    // besoin et la distribue aux membres pas encore notifiés pour cette
    // epoch. Idempotent — symétrique pour "je viens de rejoindre" et "un
    // autre membre vient de rejoindre".
    if (conv.isGroup) {
      final memberIds = conv.participants.map((p) => p.alanyaID).toList();
      _group.createOrDistribute(conv.conversID, memberIds);
    }
  }

  /// Un membre a quitté un groupe (départ volontaire, seul déclencheur de
  /// rotation — l'app n'a pas de notion d'admin/retrait forcé). Les membres
  /// restants régénèrent + redistribuent leur sender key.
  Future<void> _onGroupMemberRemoved(dynamic data) async {
    if (data is! Map) return;
    final conversationID = _toInt(data['conversationID']);
    if (conversationID == 0) return;
    final conv = await (_db.select(_db.localConversations)
          ..where((c) => c.conversID.equals(conversationID)))
        .getSingleOrNull();
    if (conv == null) return;
    try {
      final participants = jsonDecode(conv.participantsJson) as List;
      final remainingIds = participants
          .whereType<Map>()
          .map((p) => _toInt(p['alanyaID'] ?? p['id'] ?? p['userID']))
          .where((id) => id != 0)
          .toList();
      await _group.rotate(conversationID, remainingIds);
    } catch (e) {
      debugPrint('[ChatRepo] _onGroupMemberRemoved($conversationID) échoué: $e');
    }
  }

  Future<void> _onGroupKeyDistribution(dynamic data) async {
    if (data is! Map) return;
    final fromUserId = _toInt(data['fromUserId']);
    final groupId = _toInt(data['groupId']);
    final payload = data['encryptedPayload'];
    if (fromUserId == 0 || groupId == 0 || payload is! Map) return;
    try {
      final header = payload['header']?.toString();
      final plainB64 = await _e2ee.decrypt(
        fromUserId,
        payload['ciphertext']?.toString() ?? '',
        payload['nonce']?.toString() ?? '',
        header != null ? jsonDecode(header) as Map<String, dynamic> : const {},
      );
      if (plainB64 == null) return;
      await _group.processDistribution(fromUserId, groupId, plainB64);
    } catch (e) {
      debugPrint('[ChatRepo] _onGroupKeyDistribution($groupId, $fromUserId) échoué: $e');
    }
  }
 
  Future<void> syncConversations() async {
    try {
      final raw = await _api.getConversations();
      final companions = <LocalConversationsCompanion>[];
      for (final j in raw.whereType<Map<String, dynamic>>()) {
        final conv = Conversation.fromJson(j);
        var companion = _convToCompanion(conv, j);
        companion = await _preserveLocalPreview(companion);
        companions.add(companion);

        // Filet de sécurité : `conversation:created` (déclencheur normal de
        // la distribution de sender key) est un event socket ponctuel — s'il
        // est manqué (socket pas encore prêt à la création/l'ajout), ma clé
        // de groupe ne serait jamais créée/distribuée. `createOrDistribute`
        // est idempotent (no-op si déjà fait pour cette epoch), donc sûr à
        // rappeler à chaque resynchronisation.
        if (conv.isGroup) {
          final memberIds = conv.participants.map((p) => p.alanyaID).toList();
          unawaited(_group.createOrDistribute(conv.conversID, memberIds));
        }
      }
      await _dao.upsertConversations(companions);
    } catch (e) {
      debugPrint('[ChatRepo] syncConversations échouée: $e');
    }
  }

  /// Le serveur ne connaît jamais le plaintext d'une conversation chiffrée :
  /// `lastMessage` y vaut toujours le libellé générique `🔒 Message chiffré`
  /// (voir chat.js). Si on a déjà localement un aperçu déchiffré pour ce même
  /// dernier message (via socket, en clair), ne pas le régresser vers ce
  /// libellé générique à chaque resynchronisation REST.
  ///
  /// Pas de comparaison par horodatage ici (approche abandonnée) : l'écart
  /// entre l'horodatage local (capturé au tap "envoyer", avant chiffrement
  /// + upload) et celui du serveur (capturé à l'insertion, donc APRÈS)
  /// dépend de la durée de l'upload — pour une grosse vidéo (chiffrement par
  /// chunks, voir §4.4 MEDIAS_E2EE.md) cet écart dépasse facilement plusieurs
  /// dizaines de secondes, rendant toute fenêtre de tolérance fixe non-fiable
  /// (régression observée : aperçu vidéo qui retombe sur le libellé générique
  /// dès qu'un resync survient après la fenêtre). Le flux socket live
  /// (`_bumpConversationSummary` sur envoi/réception) reste l'unique source
  /// de vérité pour faire AVANCER l'aperçu vers un message plus récent ; ce
  /// resync REST ne sert qu'à ne jamais le faire RÉGRESSER.
  Future<LocalConversationsCompanion> _preserveLocalPreview(
      LocalConversationsCompanion incoming) async {
    if (incoming.lastMessage.value != '🔒 Message chiffré') return incoming;

    final conversID = incoming.conversID.value;
    final existing = await (_db.select(_db.localConversations)
          ..where((c) => c.conversID.equals(conversID)))
        .getSingleOrNull();
    if (existing == null) return incoming;

    final localPreviewIsBetter = existing.lastMessage != null &&
        existing.lastMessage!.isNotEmpty &&
        existing.lastMessage != '🔒 Message chiffré';

    if (localPreviewIsBetter) {
      return incoming.copyWith(
        lastMessage: Value(existing.lastMessage),
        lastMessageAt: Value(existing.lastMessageAt),
        lastMessageSenderID: Value(existing.lastMessageSenderID),
        lastMessageType: Value(existing.lastMessageType),
        lastMessageStatus: Value(existing.lastMessageStatus),
      );
    }
    return incoming;
  }

  /// Charge l'historique d'une conversation.
  /// Si `delta == true`, ne récupère que les messages plus récents que le
  /// dernier confirmé en local (curseur `after` côté API).
  Future<void> syncMessages(int conversationID, {bool delta = false}) async {
    try {
      List<dynamic> raw;
      if (delta) {
        final last = await _dao.maxServerMsgId(conversationID);
        raw = await _api.getMessages(conversationID, limit: 50, after: last > 0 ? last : null);
      } else {
        raw = await _api.getMessages(conversationID, limit: 50);
      }
      for (final j in raw.whereType<Map<String, dynamic>>()) {
        await _upsertServerMsg(await _decryptIfNeeded(j), prefetchMedia: true);
      }
    } catch (e) {
      debugPrint('[ChatRepo] syncMessages($conversationID) échouée: $e');
    }
  }

  /// Charge une page d'anciens messages
  Future<int> loadOlderMessages(int conversationID, {int limit = 30}) async {
    try {
      final oldest = await _dao.minServerMsgId(conversationID);
      if (oldest == 0) return 0;
      final raw = await _api.getMessages(conversationID, limit: limit, before: oldest);
      final list = raw.whereType<Map<String, dynamic>>().toList();
      for (final j in list) {
        await _upsertServerMsg(await _decryptIfNeeded(j), prefetchMedia: true);
      }
      return list.length;
    } catch (e) {
      debugPrint('[ChatRepo] loadOlderMessages échouée: $e');
      return 0;
    }
  }

  Future<void> sendText({
    required int conversationID,
    required String content,
    int? replyToID,
    String? replyToContent,
    int isStatusReply = 0,
  }) async {
    if (_myId == 0) {
      debugPrint('[ChatRepo] sendText ignoré : utilisateur non lié (myId=0)');
      return;
    }
    final clientId = _newClientId();
    final now = DateTime.now().toUtc();

    await _dao.upsertMessage(LocalMessagesCompanion.insert(
      clientId: clientId,
      conversationID: conversationID,
      senderID: _myId,
      sendAt: now,
      content: Value(content),
      type: const Value(0),
      status: const Value(0),
      replyToID: Value(replyToID),
      replyToContent: Value(replyToContent),
      isStatusReply: Value(isStatusReply),
      syncPending: const Value(true),
    ));
    _bumpConversationSummary(conversationID, content, 0, now,
        senderID: _myId, status: 0);

    await _emitSend(
      clientId: clientId,
      conversationID: conversationID,
      content: content,
      type: 0,
      replyToID: replyToID,
      replyToContent: replyToContent,
      isStatusReply: isStatusReply,
    );
  }

  /// Aperçu canonique pour les messages média : on respecte le `content` saisi
  /// s'il existe, sinon on retombe sur l'emoji + libellé de type. Évite que
  /// l'aperçu de conv affiche un nom de fichier brut (`IMG_2026.jpg`).
  /// Pour un média (type != 0), le texte de repli `_kEncryptedFallback` n'est
  /// JAMAIS une légende réelle (les messages média n'en ont pas côté E2EE) —
  /// l'ignorer pour retomber sur l'emoji plutôt que de figer "Message
  /// chiffré" dans l'aperçu de conversation si un resync concurrent échoue à
  /// redéchiffrer (Double Ratchet / Sender Keys à usage unique).
  static String _previewForMedia(int type, String? content, String? mediaName) {
    final hasRealContent = content != null &&
        content.trim().isNotEmpty &&
        (type == 0 || content != _kEncryptedFallback);
    if (hasRealContent) return content;
    switch (type) {
      case 1:
        return '📷 Photo';
      case 2:
        return '🎥 Vidéo';
      case 3:
        return '🎵 Audio';
      case 4:
        return mediaName?.isNotEmpty == true ? '📎 $mediaName' : '📎 Fichier';
      default:
        return mediaName ?? 'Média';
    }
  }


  /// Envoi média avec envelope encryption (voir MEDIAS_E2EE.md) : le fichier
  /// est chiffré en AES-256-GCM avec une clé jetable AVANT l'upload — le
  /// serveur ne reçoit qu'un blob opaque. La clé (+ id du blob, hash, mime,
  /// taille, nom réel) voyage ensuite comme `content` d'un message normal,
  /// donc `_emitSend` la chiffre déjà via le ratchet 1-1 ou les Sender Keys
  /// de groupe — rien de spécifique aux groupes à réimplémenter ici.
  Future<void> sendEncryptedMediaFile({
    required int conversationID,
    required int type, // 1=image 2=vidéo 3=audio 4=fichier
    required File file,
    String? mediaName,
    int? mediaDuration,
  }) async {
    if (_myId == 0) {
      debugPrint('[ChatRepo] sendEncryptedMediaFile ignoré : utilisateur non lié (myId=0)');
      return;
    }
    final clientId = _newClientId();
    final now = DateTime.now().toUtc();
    final name = mediaName ?? file.path.split('/').last;

    await _dao.upsertMessage(LocalMessagesCompanion.insert(
      clientId: clientId,
      conversationID: conversationID,
      senderID: _myId,
      sendAt: now,
      type: Value(type),
      status: const Value(0),
      mediaName: Value(name),
      mediaDuration: Value(mediaDuration),
      localMediaPath: Value(file.path),
      syncPending: const Value(true),
    ));
    _bumpConversationSummary(
        conversationID, _previewForMedia(type, null, name), type, now,
        senderID: _myId, status: 0);

    _sendsInFlight.add(clientId);
    try {
      final plainLength = await file.length();
      const chunkSize = MediaCipherService.defaultChunkSize;
      final mediaKey = await _mediaCipher.newMediaKey();
      final encryptedLength = MediaCipherService.encryptedLengthFor(plainLength, chunkSize);

      // Miniature (voir §4.3 MEDIAS_E2EE.md) : petite, elle voyage EN CLAIR
      // dans l'enveloppe (donc chiffrée avec le reste du message par le
      // ratchet/GroupCipher) — pas de clé ni d'upload séparés. Images et
      // vidéos (frame extraite à 0 ms) uniquement.
      String? thumbnailB64;
      if (type == 1) {
        try {
          final thumbBytes = await FlutterImageCompress.compressWithFile(
            file.path,
            minWidth: 160,
            minHeight: 160,
            quality: 40,
            format: CompressFormat.jpeg,
          );
          if (thumbBytes != null) thumbnailB64 = base64Encode(thumbBytes);
        } catch (e) {
          debugPrint('[ChatRepo] génération miniature échouée: $e');
        }
      } else if (type == 2) {
        try {
          final thumbBytes = await VideoThumbnail.thumbnailData(
            video: file.path,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 160,
            maxHeight: 160,
            quality: 40,
          );
          if (thumbBytes != null) thumbnailB64 = base64Encode(thumbBytes);
        } catch (e) {
          debugPrint('[ChatRepo] génération miniature vidéo échouée: $e');
        }
      }

      // Chiffrement + upload en streaming (voir §4.4 MEDIAS_E2EE.md) : le
      // fichier n'est jamais chargé entièrement en mémoire, même pour une
      // grosse vidéo. Le hash du blob chiffré (intégrité, vérifié par le
      // destinataire avant déchiffrement) est calculé à la volée en
      // observant le flux au passage, sans le bufferiser une seconde fois.
      final hashSink = Sha256().newHashSink();
      final encryptedStream = _mediaCipher
          .encryptFileStreaming(file, mediaKey, chunkSize: chunkSize)
          .map((chunk) {
        hashSink.add(chunk);
        return chunk;
      });

      final uploaded = await _api.uploadEncryptedStream(encryptedStream, encryptedLength);
      hashSink.close();
      final blobHash = (await hashSink.hash()).bytes;

      final envelope = jsonEncode({
        'v': 1,
        'mediaKey': base64Encode(await mediaKey.extractBytes()),
        'mediaId': uploaded['id'],
        'sha256': base64Encode(blobHash),
        'mime': lookupMimeType(file.path) ?? 'application/octet-stream',
        'size': plainLength,
        'name': name,
        if (thumbnailB64 != null) 'thumbnail': thumbnailB64,
      });

      // Persisté AVANT l'émission : si le socket n'est pas prêt, `_emitSend`
      // revient sans rien envoyer, mais `flushOutbox` retrouvera l'enveloppe
      // déjà construite via `mediaEnvelope` pour rejouer l'envoi sans
      // re-uploader le blob.
      await (_db.update(_db.localMessages)..where((m) => m.clientId.equals(clientId)))
          .write(LocalMessagesCompanion(
        mediaEnvelope: Value(envelope),
        status: const Value(1), // envoyé (message:sent affinera ensuite)
      ));

      await _emitSend(
        clientId: clientId,
        conversationID: conversationID,
        content: envelope,
        type: type,
      );
    } catch (e) {
      debugPrint('[ChatRepo] envoi média chiffré échoué: $e');
      // Contrairement au flux legacy, un échec ici (chiffrement ou upload)
      // n'a pas d'équivalent "pendingUploadPath" rejouable par flushOutbox :
      // on échoue directement, l'utilisateur réessaie depuis le sélecteur.
      await _dao.markFailed(clientId);
    } finally {
      _sendsInFlight.remove(clientId);
    }
  }

  /// Renvoie tous les messages en attente (appelé à la reconnexion socket).
  /// Le média E2EE est déjà chiffré+uploadé avant l'émission (voir
  /// `sendEncryptedMediaFile`) : il ne reste jamais qu'à rejouer l'enveloppe
  /// (`mediaEnvelope`) si seule l'émission a échoué/été différée.
  Future<void> flushOutbox() async {
    final pending = await _dao.pendingMessages();
    for (final m in pending) {
      // Un envoi média chiffré est déjà en cours (chiffrement/upload) pour ce
      // clientId : ne pas le retraiter, sous peine d'émettre le message deux
      // fois (le serveur ne déduplique pas par clientId).
      if (_sendsInFlight.contains(m.clientId)) continue;
      // Média E2EE déjà chiffré+uploadé (blob + enveloppe prêts, seule
      // l'émission avait échoué/été différée) : rejouer l'enveloppe telle
      // quelle plutôt que `content` (resté null pour ne pas fuiter en
      // légende — voir `sendEncryptedMediaFile`). Le nom/URL du média sont
      // DÉJÀ dans l'enveloppe chiffrée : ne jamais les repasser en clair ici
      // (seul le flux legacy, sans mediaEnvelope, en a légitimement besoin).
      final isE2eeMedia = m.mediaEnvelope != null;
      await _emitSend(
        clientId: m.clientId,
        conversationID: m.conversationID,
        content: m.mediaEnvelope ?? m.content,
        type: m.type,
        mediaUrl: isE2eeMedia ? null : m.mediaUrl,
        mediaName: isE2eeMedia ? null : m.mediaName,
        mediaDuration: isE2eeMedia ? null : m.mediaDuration,
        replyToID: m.replyToID,
        replyToContent: m.replyToContent,
      );
    }
    // Rejoue les accusés de lecture émis hors-ligne.
    if (_api.isSocketReady && _pendingReads.isNotEmpty) {
      for (final convID in _pendingReads.toList()) {
        _api.sendSocketEvent(SocketEvents.messageRead, {'conversationID': convID});
      }
      _pendingReads.clear();
    }

    // Retry des messages marqués failed (status==4) avec retryCount < 3
    final failed = await (_db.select(_db.localMessages)
          ..where((m) => m.status.equals(4) & m.retryCount.isSmallerThanValue(3)))
        .get();
    for (final m in failed) {
      await _dao.incrementRetryCount(m.clientId);
      // Message texte ou média déjà chiffré+uploadé : remettre en pending et réémettre.
      await _dao.retryFailed(m.clientId);
      final isE2eeMedia = m.mediaEnvelope != null;
      await _emitSend(
        clientId: m.clientId,
        conversationID: m.conversationID,
        content: m.mediaEnvelope ?? m.content,
        type: m.type,
        mediaUrl: isE2eeMedia ? null : m.mediaUrl,
        mediaName: isE2eeMedia ? null : m.mediaName,
        mediaDuration: isE2eeMedia ? null : m.mediaDuration,
        replyToID: m.replyToID,
        replyToContent: m.replyToContent,
      );
    }
  }

  /// Modifie un message texte (le mien). Applique localement puis serveur.
  Future<void> editMessage(int msgID, String content) async {
    await _dao.updateContentByServerId(msgID, content);
    try {
      await _api.editMessage(msgID, content);
    } catch (e) {
      debugPrint('[ChatRepo] editMessage échouée: $e');
    }
  }

  /// Supprime un message :
  ///  - [forAll]=true : soft delete partagé (`isDeleted=1`), le bubble devient
  ///    « Ce message a été supprimé » côté tous les participants.
  ///  - [forAll]=false : suppression locale uniquement, on pose `deletedForID`
  ///    sur l'utilisateur courant pour le masquer pour lui seul.
  Future<void> deleteMessage(int msgID, {bool forAll = false}) async {
    if (forAll) {
      await _dao.softDeleteByServerId(msgID);
    } else {
      await _dao.softDeleteForUser(msgID, _myId);
    }
    try {
      await _api.deleteMessage(msgID, forAll: forAll);
    } catch (e) {
      debugPrint('[ChatRepo] deleteMessage échouée: $e');
    }
  }

  /// Remet un message échoué en file d'envoi (déclenché par l'utilisateur via
  /// le menu contextuel). Le prochain `flushOutbox` le rejoue.
  Future<void> retryMessage(String clientId) async {
    await _dao.retryFailed(clientId);
    if (_api.isSocketReady) {
      await flushOutbox();
    }
  }

  /// Met à jour l'épinglage côté serveur (conv_participants) puis localement.
  /// Optimistic : on écrit la valeur en cache d'abord pour un feedback instantané.
  Future<void> setConversationPinned(int conversID, bool pinned) async {
    await _dao.setPinned(conversID, pinned);
    try {
      await _api.updateConversation(conversID, isPinned: pinned);
    } catch (e) {
      await _dao.setPinned(conversID, !pinned);
      rethrow;
    }
  }

  Future<void> setConversationArchived(int conversID, bool archived) async {
    await _dao.setArchived(conversID, archived);
    try {
      await _api.updateConversation(conversID, isArchived: archived);
    } catch (e) {
      await _dao.setArchived(conversID, !archived);
      rethrow;
    }
  }

  Future<void> markAsRead(int conversationID) async {
    await _dao.markConversationReadAtomic(conversationID, _myId);
    if (_api.isSocketReady) {
      try {
        _api.sendSocketEvent(SocketEvents.messageRead, {'conversationID': conversationID});
        _pendingReadsRetry.remove(conversationID);
      } catch (e) {
        debugPrint('[ChatRepo] sendSocketEvent failed: $e');
        _pendingReadsRetry[conversationID] = (_pendingReadsRetry[conversationID] ?? 0) + 1;
      }
    } else {
      // Hors-ligne ou socket non-authentifié : stocker pour rejouer plus tard.
      _pendingReadsRetry[conversationID] = (_pendingReadsRetry[conversationID] ?? 0);
    }
    try {
      await _api.markConversationAsRead(conversationID);
    } catch (e) {
      debugPrint('[ChatRepo] markConversationAsRead HTTP failed: $e');
    }
  }

  /// Re-sync de la conversation actuellement à l'écran après reconnexion.
  /// Évite à l'utilisateur de quitter/rouvrir la conv pour voir les messages
  /// reçus pendant la coupure.
  Future<void> resyncActiveConversation() async {
    if (_activeConversationID == 0) return;
    await syncMessages(_activeConversationID, delta: true);
  }

  /// Ré-émet `joinConversation` pour la conv active après reconnexion (les
  /// rooms socket.io sont volatiles, le serveur ne les restaure pas).
  void rejoinActiveRoom() {
    if (_activeConversationID == 0) return;
    if (!_api.isSocketReady) return;
    _api.sendSocketEvent(
      SocketEvents.joinConversation,
      {'conversationID': _activeConversationID},
    );
  }

  Future<void> _flushPendingReads() async {
    if (!_api.isSocketReady || _pendingReadsRetry.isEmpty) return;
    for (final convID in _pendingReadsRetry.keys.toList()) {
      try {
        _api.sendSocketEvent(SocketEvents.messageRead, {'conversationID': convID});
        _pendingReadsRetry.remove(convID);
      } catch (e) {
        debugPrint('[ChatRepo] _flushPendingReads send failed for $convID: $e');
        _pendingReadsRetry[convID] = (_pendingReadsRetry[convID] ?? 0) + 1;
        if ((_pendingReadsRetry[convID] ?? 0) > 3) _pendingReadsRetry.remove(convID);
      }
    }
  }


  /// Retourne l'ID du destinataire pour une conversation 1-1, null pour un groupe.
  Future<int?> _getRecipientId(int conversationId) async {
    final conv = await (_db.select(_db.localConversations)
          ..where((c) => c.conversID.equals(conversationId)))
        .getSingleOrNull();
    if (conv == null || conv.isGroup) return null;
    try {
      final List<dynamic> list = jsonDecode(conv.participantsJson);
      for (final p in list) {
        if (p is! Map) continue;
        final id = (p['alanyaID'] ?? p['id'] ?? p['userID']) as int?;
        if (id != null && id != _myId) return id;
      }
    } catch (_) {}
    return null;
  }

  /// Déchiffre les champs `ciphertext`+`nonce`+`header` d'un message entrant si présents.
  /// Injecte le plaintext dans `content` et supprime les champs crypto du JSON.
  /// Pour mes propres messages (écho serveur), retire les champs crypto uniquement :
  /// `_upsertServerMsg` restaurera le plaintext depuis la copie locale.
  Future<Map<String, dynamic>> _decryptIfNeeded(Map<String, dynamic> j) async {
    final ciphertext   = j['ciphertext']?.toString();
    final nonce        = j['nonce']?.toString();
    final archiveBlob  = j['archive_blob']?.toString();
    final archiveNonce = j['archive_nonce']?.toString();

    final result = Map<String, dynamic>.from(j)
      ..remove('ciphertext')
      ..remove('nonce')
      ..remove('header')
      ..remove('archive_blob')
      ..remove('archive_nonce');

    final senderId = _toInt(j['senderID']);

    if (senderId == _myId) {
      // Mon propre message : la copie locale a le plaintext (optimistic upsert).
      // Sur un nouvel appareil (pas de copie locale) : décrypter via le coffre.
      if (archiveBlob != null && archiveNonce != null) {
        final plain = await _vault.open(archiveBlob, archiveNonce);
        if (plain != null) result['content'] = plain;
      }
      return _relocateMediaEnvelope(result, j['type']);
    }

    if (ciphertext == null) return result;

    final conversationID = _toInt(j['conversationID']);
    final conv = await (_db.select(_db.localConversations)
          ..where((c) => c.conversID.equals(conversationID)))
        .getSingleOrNull();

    if (conv != null && conv.isGroup) {
      // Message de groupe : Sender Key (libsignal_protocol_dart). Pas de
      // `header` — juste le ciphertext, keyé par (groupe, expéditeur).
      final plaintext = await _group.decrypt(conversationID, senderId, ciphertext);
      result['content'] = plaintext ?? _kEncryptedFallback;
      return _relocateMediaEnvelope(result, j['type']);
    }

    // Message 1-1 d'un autre : déchiffrement Double Ratchet.
    if (nonce == null) return result;

    final headerStr = j['header']?.toString();
    Map<String, dynamic>? header;
    if (headerStr != null && headerStr.isNotEmpty) {
      try {
        header = jsonDecode(headerStr) as Map<String, dynamic>;
      } catch (_) {}
    }

    if (header == null) {
      result['content'] = _kEncryptedFallback;
      return result;
    }

    final plaintext = await _e2ee.decrypt(senderId, ciphertext, nonce, header);
    result['content'] = plaintext ?? _kEncryptedFallback;
    return _relocateMediaEnvelope(result, j['type']);
  }

  /// Un message média E2EE porte, une fois déchiffré, l'enveloppe JSON
  /// (clé média, id du blob, hash, mime, taille, nom) — jamais un texte
  /// affichable. On la sort de `content` (qui alimente la légende visible
  /// des bulles média, voir chat_bubbles.dart) vers `mediaEnvelope`, lue
  /// uniquement par `_resolveEncryptedMedia`.
  Map<String, dynamic> _relocateMediaEnvelope(Map<String, dynamic> result, dynamic typeVal) {
    if (_toInt(typeVal) == 0) return result;
    final content = result['content']?.toString();
    if (content == null || content.isEmpty || content == _kEncryptedFallback) return result;
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map && decoded.containsKey('mediaKey')) {
        result['mediaEnvelope'] = content;
        result['content'] = null;
      }
    } catch (_) {
      // Pas du JSON : légende/texte de repli normal, on laisse tel quel.
    }
    return result;
  }

  /// Récupère l'historique des messages archivés (coffre) pour une conversation.
  /// Déchiffre chaque `archive_blob` avec la clé de coffre et upsert en local.
  /// À appeler sur un nouvel appareil après avoir déverrouillé le coffre.
  Future<void> syncVaultHistory(int conversationId) async {
    if (!_vault.isUnlocked) {
      debugPrint('[Vault] syncVaultHistory ignoré : coffre verrouillé');
      return;
    }
    try {
      final rows = await _api.fetchVaultHistory(conversationId);
      for (final row in rows) {
        final blob  = row['archive_blob']?.toString();
        final bNonce = row['archive_nonce']?.toString();
        if (blob == null || bNonce == null) continue;
        final plain = await _vault.open(blob, bNonce);
        if (plain != null) {
          final enriched = Map<String, dynamic>.from(row)
            ..['content'] = plain
            ..remove('archive_blob')
            ..remove('archive_nonce');
          await _upsertServerMsg(_relocateMediaEnvelope(enriched, row['type']));
        }
      }
    } catch (e) {
      debugPrint('[Vault] syncVaultHistory($conversationId) échouée: $e');
    }
  }

  Future<void> _upsertServerMsg(
    Map<String, dynamic> json, {
    bool prefetchMedia = false,
  }) async {
    final msgID = _toInt(json['msgID']);
    final convID = _toInt(json['conversationID']);
    if (msgID == 0) {
      await _dao.upsertMessage(_msgJsonToCompanion(json));
      return;
    }

    final srvKey = 'srv_$msgID';
    final clientId = json['clientId']?.toString();
    final content = json['content']?.toString();
    final mediaName = json['mediaName']?.toString();
    bool wasNew = false;
    await _db.transaction(() async {
      String? carriedLocalPath;
      String? carriedContent;
      // Média E2EE : `mediaName` ne voyage jamais en clair (voir
      // sendEncryptedMediaFile), il faut donc le récupérer depuis la ligne
      // optimiste locale plutôt que depuis l'écho serveur.
      String? carriedMediaName;
      String? carriedMediaEnvelope;

      // Un message déjà confirmé (ex: écho E2EE re-synchronisé après coup, ou
      // ratchet Double Ratchet qui ne peut pas redéchiffrer une 2e fois une
      // clé de message déjà consommée) ne doit jamais voir son plaintext
      // local remplacé par un `content` vide venant d'un nouveau fetch.
      final existing = await (_db.select(_db.localMessages)
            ..where((m) => m.clientId.equals(srvKey)))
          .getSingleOrNull();
      if (existing != null && existing.content != null && existing.content!.isNotEmpty) {
        carriedContent ??= existing.content;
      }
      // Média déjà résolu une 1ère fois (enveloppe stockée ou fichier déjà en
      // cache) : un nouveau décryptage de la MÊME ciphertext échoue TOUJOURS
      // en cas de resynchronisation ou de livraison dupliquée (Double Ratchet
      // et Sender Keys sont à usage unique). Le média reste valide — il ne
      // faut jamais régresser la légende vers le texte de repli dans ce cas.
      final mediaAlreadyResolved = existing != null &&
          (existing.mediaEnvelope != null || existing.localMediaPath != null);

      final candidates = await (_db.select(_db.localMessages)
            ..where((m) {
              // Ligne déjà confirmée avec le même msgID mais clé différente
              final sameOtherKey = m.msgID.equals(msgID) & m.clientId.equals(srvKey).not();

              // Base optimiste : même conversation et msgID==0
              final optimisticBase = m.conversationID.equals(convID) & m.msgID.equals(0);

              // Match prioritaire par clientId si fourni par le serveur
              Expression<bool> optimistic = const Constant(false);
              if (clientId != null && clientId.isNotEmpty) {
                optimistic = optimisticBase & m.clientId.equals(clientId);
              } else if (content != null && content.isNotEmpty) {
                // Pour matcher sur le contenu, restreindre au messages dont
                // l'émetteur local est bien l'utilisateur courant (évite collisions)
                optimistic = optimisticBase & m.content.equals(content) & m.senderID.equals(_myId);
              } else if (mediaName != null && mediaName.isNotEmpty) {
                optimistic = optimisticBase & m.mediaName.equals(mediaName) & m.senderID.equals(_myId);
              }

              return sameOtherKey | optimistic;
            }))
          .get();

      // Nouveau message local si aucun candidat avec ce msgID confirmé
      wasNew = candidates.every((m) => m.msgID != msgID);

      for (final m in candidates) {
        carriedLocalPath ??= m.localMediaPath;
        carriedMediaName ??= m.mediaName;
        carriedMediaEnvelope ??= m.mediaEnvelope;
        if (m.content != null && m.content!.isNotEmpty) carriedContent ??= m.content;
        await (_db.delete(_db.localMessages)..where((x) => x.clientId.equals(m.clientId))).go();
      }

      // Insère une seule ligne normalisée `srv_<msgID>` (clé primaire stable).
      var companion = _msgJsonToCompanion(json).copyWith(clientId: Value(srvKey));
      if (carriedLocalPath != null) {
        companion = companion.copyWith(localMediaPath: Value(carriedLocalPath));
      }
      if (companion.mediaName.value == null && carriedMediaName != null) {
        companion = companion.copyWith(mediaName: Value(carriedMediaName));
      }
      if (companion.mediaEnvelope.value == null && carriedMediaEnvelope != null) {
        companion = companion.copyWith(mediaEnvelope: Value(carriedMediaEnvelope));
      }
      // Si l'écho/la resynchronisation n'apporte pas de plaintext réel (soit
      // `content` absent — mes propres messages —, soit le texte de repli
      // générique — une resynchronisation qui retente un déchiffrement déjà
      // consommé, Double Ratchet et Sender Keys étant tous deux à usage
      // unique), on restaure le plaintext déjà connu depuis la copie locale
      // plutôt que de régresser vers du vide/repli.
      final incomingHasNoRealContent = companion.content.value == null ||
          companion.content.value == _kEncryptedFallback;
      if (incomingHasNoRealContent && carriedContent != null) {
        companion = companion.copyWith(content: Value(carriedContent));
      } else if (mediaAlreadyResolved && companion.content.value == _kEncryptedFallback) {
        // Média déjà connu (voir `mediaAlreadyResolved` ci-dessus) : pas de
        // contenu réel à restaurer (les messages média n'ont normalement pas
        // de légende), mais on doit quand même supprimer le texte de repli
        // parasite plutôt que de l'afficher sous un média pourtant valide.
        companion = companion.copyWith(content: const Value(null));
      }

      debugPrint('[ChatRepo] _upsertServerMsg msgID=$msgID conv=$convID candidates=${candidates.length} wasNew=$wasNew');
      await _dao.upsertMessage(companion);
    });

    if (wasNew) {
      final mediaEnvelope = json['mediaEnvelope']?.toString();
      if (mediaEnvelope != null && mediaEnvelope.isNotEmpty) {
        // Média E2EE : toujours résoudre (télécharger + déchiffrer + cacher)
        // dès qu'on découvre le message, réception live ou resync historique
        // — sans quoi la bulle resterait indéfiniment vide (pas d'action
        // manuelle équivalente au tap-to-load du flux legacy pour l'instant).
        unawaited(_resolveEncryptedMedia(msgID, mediaEnvelope));
      } else if (prefetchMedia) {
        // Préfetch média legacy (images/audio toujours, fichiers < 5 Mo) pour
        // rendre l'historique consultable offline.
        final mtype = _toInt(json['type']);
        final mediaUrl = json['mediaUrl']?.toString();
        if (mediaUrl != null && mediaUrl.isNotEmpty) {
          if (mtype == 1 || mtype == 3) {
            _cacheMedia(msgID, mediaUrl);
          } else if (mtype == 4) {
            _cacheMedia(msgID, mediaUrl, maxBytes: 5 * 1024 * 1024);
          }
        }
      }
    }
  }

  /// Résout un média E2EE reçu : télécharge le blob chiffré et le déchiffre
  /// en streaming (jamais bufferisé entièrement, même pour une grosse
  /// vidéo — voir §4.4 MEDIAS_E2EE.md), écrit le résultat dans un fichier
  /// temporaire, vérifie son intégrité (hash calculé côté émetteur avant
  /// upload) puis ne le promeut au chemin final que si le hash correspond.
  /// Contrairement au ratchet/Sender Keys, la clé média AES-GCM n'est pas à
  /// usage unique : appeler ceci plusieurs fois pour le même message est
  /// sans risque, juste redondant (d'où le garde `wasNew` à l'appel).
  Future<void> _resolveEncryptedMedia(int msgID, String envelopeJson) async {
    File? tmpFile;
    try {
      final env = jsonDecode(envelopeJson) as Map<String, dynamic>;
      final mediaId = _toInt(env['mediaId']);
      final mediaKey = SecretKey(base64Decode(env['mediaKey'] as String));
      final expectedHash = base64Decode(env['sha256'] as String);

      final base = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(p.join(base.path, 'media_cache', 'e2ee'));
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final name = (env['name'] as String?) ?? 'media_$mediaId';
      final finalPath = p.join(cacheDir.path, '${msgID}_$name');
      tmpFile = File('$finalPath.part');

      final hashSink = Sha256().newHashSink();
      final encryptedStream = _api.downloadMediaBlobStreaming(mediaId).map((chunk) {
        hashSink.add(chunk);
        return chunk;
      });

      final sink = tmpFile.openWrite();
      await for (final clearChunk in _mediaCipher.decryptStreaming(encryptedStream, mediaKey)) {
        sink.add(clearChunk);
      }
      await sink.close();

      hashSink.close();
      final actualHash = (await hashSink.hash()).bytes;
      if (!MediaCipherService.bytesEqual(actualHash, expectedHash)) {
        debugPrint('[ChatRepo] média E2EE msgID=$msgID: hash invalide, blob rejeté');
        await tmpFile.delete();
        return;
      }

      await tmpFile.rename(finalPath);
      await _dao.setResolvedMedia(msgID, localPath: finalPath, mediaName: env['name'] as String?);
    } catch (e) {
      debugPrint('[ChatRepo] résolution média E2EE échouée msgID=$msgID: $e');
      if (tmpFile != null && await tmpFile.exists()) {
        await tmpFile.delete();
      }
    }
  }

  Future<void> _onMessageReceived(dynamic data) async {
    if (data is! Map) return;
    final json = await _decryptIfNeeded(Map<String, dynamic>.from(data));
    final senderID0 = _toInt(json['senderID']);

    await _upsertServerMsg(json);
    if (senderID0 == _myId) return;

    final convID = _toInt(json['conversationID']);
    final type = _toInt(json['type']);
    final preview = _previewForMedia(
      type,
      json['content']?.toString(),
      json['mediaName']?.toString(),
    );
    final at = _parseDate(json['sendAt']) ?? DateTime.now().toUtc();
    final isActive = convID != 0 && convID == _activeConversationID;

    // Conversation ouverte → message lu immédiatement (pas de badge non-lu).
    _bumpConversationSummary(convID, preview, type, at,
        fromOther: !isActive, senderID: senderID0);
    if (isActive) {
      await _dao.markConversationRead(convID, _myId);
      await _dao.setUnread(convID, 0);
    }

    if (convID != 0 && _api.isSocketConnected) {
      // Conversation ouverte → "lu" (✓✓ bleu) ; sinon "livré".
      _api.sendSocketEvent(
        isActive ? SocketEvents.messageRead : SocketEvents.messageDelivered,
        {'conversationID': convID},
      );
    }
    final mtype = _toInt(json['type']);
    final mediaUrl = json['mediaUrl']?.toString();
    final msgID = _toInt(json['msgID']);
    if (mediaUrl != null && msgID != 0) {
      if (mtype == 1 || mtype == 3) {
        // Images, audio : auto-cache toujours.
        _cacheMedia(msgID, mediaUrl);
      } else if (mtype == 4) {
        // Fichiers : auto-cache si < 5 MB (sinon coût data trop élevé,
        // ouverture manuelle redéclenchera ensureCached).
        _cacheMedia(msgID, mediaUrl, maxBytes: 5 * 1024 * 1024);
      }
      // Vidéos (mtype==2) : on-demand uniquement (déjà via tap → ensureCached).
    }
  }

  Future<void> _cacheMedia(int msgID, String url, {int? maxBytes}) async {
    final path = await _mediaCache.ensureCached(url, maxBytes: maxBytes);
    if (path != null) await _dao.setLocalMediaPath(msgID, path);
  }

  void _onMessageStatus(dynamic data) {
    if (data is! Map) return;
    final convID = _toInt(data['conversationID']);
    final status = _toInt(data['status']);
    final byUserID = _toInt(data['byUserID']);
    if (convID == 0 || status == 0 || byUserID == _myId) return;
    _dao.bumpMyMessagesStatus(convID, _myId, status);
    // Reflète l'accusé (✓✓ / ✓✓ bleu) sur l'aperçu si le dernier message est le mien.
    _dao.bumpConvLastStatusIfMine(convID, _myId, status);
  }

  Future<void> _onMessageSent(dynamic data) async {
    if (data is! Map) return;
    final json = Map<String, dynamic>.from(data);
    final msgID = _toInt(json['msgID']);
    if (msgID == 0) return;
    await _upsertServerMsg(json);
    // Mon message est confirmé "envoyé" → ✓ sur l'aperçu.
    final convID = _toInt(json['conversationID']);
    final status = _toInt(json['status'], fallback: 1);
    if (convID != 0) _dao.bumpConvLastStatusIfMine(convID, _myId, status);
  }

  void _onMessageUpdated(dynamic data) {
    if (data is! Map) return;
    final id = _toInt(data['msgID']);
    final content = data['content']?.toString();
    if (id != 0 && content != null) _dao.updateContentByServerId(id, content);
  }

  void _onMessageDeleted(dynamic data) {
    if (data is! Map) return;
    final id = _toInt(data['msgID']);
    if (id != 0) _dao.softDeleteByServerId(id);
  }

  Future<void> _emitSend({
    required String clientId,
    required int conversationID,
    String? content,
    required int type,
    String? mediaUrl,
    String? mediaName,
    int? mediaDuration,
    int? replyToID,
    String? replyToContent,
    int isStatusReply = 0,
  }) async {
    if (!_api.isSocketReady) {
      debugPrint('[ChatRepo] _emitSend différé (socket non prêt) clientId=$clientId');
      return;
    }

    // Chiffrement E2EE : Double Ratchet 1-1, Sender Keys pour les groupes.
    E2eePayload? payload;
    GroupEncryptResult? groupPayload;
    if (content != null && content.isNotEmpty) {
      final conv = await (_db.select(_db.localConversations)
            ..where((c) => c.conversID.equals(conversationID)))
          .getSingleOrNull();
      if (conv != null && conv.isGroup) {
        groupPayload = await _group.encrypt(conversationID, content);
      } else {
        final recipientId = await _getRecipientId(conversationID);
        if (recipientId != null) {
          payload = await _e2ee.encrypt(recipientId, content);
        }
      }

      if (payload == null && groupPayload == null) {
        // Ne JAMAIS envoyer `content` en clair au serveur : mieux vaut un
        // échec visible (retentable via flushOutbox) qu'une fuite — pour un
        // message média, `content` porte l'enveloppe avec la clé AES en
        // clair, pas juste un texte. Cause typique : conversation pas encore
        // en cache local (`localConversations`) ou session ratchet / sender
        // key pas encore disponible au moment de l'envoi.
        debugPrint('[ChatRepo] _emitSend abandonné (chiffrement impossible) '
            'clientId=$clientId conv=$conversationID — marqué en échec, '
            'jamais envoyé en clair.');
        await _dao.markFailed(clientId);
        return;
      }
    }

    // Coffre F3 : second layer AES-GCM pour l'archivage de l'historique.
    ({String blob, String nonce})? archive;
    if (content != null && content.isNotEmpty) {
      archive = await _vault.seal(content);
    }

    _api.sendSocketEvent(SocketEvents.messageSend, {
      'clientId': clientId,
      'conversationID': conversationID,
      // E2EE : ciphertext + nonce + header DR (1-1), ou ciphertext Sender Key
      // (groupe). Le cas "ni l'un ni l'autre" est intercepté au-dessus —
      // cette branche `content` en clair ne sert plus qu'aux cas où `content`
      // est une chaîne vide (rien à chiffrer, rien à fuiter).
      if (payload != null) ...payload.toSocketMap()
      else if (groupPayload != null) ...groupPayload.toSocketMap()
      else if (content != null) 'content': content,
      // Coffre : blob chiffré pour récupération d'historique sur nouvel appareil.
      if (archive != null) 'archive_blob': archive.blob,
      if (archive != null) 'archive_nonce': archive.nonce,
      'type': type,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (mediaName != null) 'mediaName': mediaName,
      if (mediaDuration != null) 'mediaDuration': mediaDuration,
      if (replyToID != null) 'replyToID': replyToID,
      if (replyToContent != null) 'replyToContent': replyToContent,
      if (isStatusReply != 0) 'isStatusReply': isStatusReply,
    });
    _dao.touchEmitted(clientId);
  }

  Future<void> _bumpConversationSummary(
    int conversID,
    String preview,
    int type,
    DateTime at, {
    bool fromOther = false,
    int? senderID,
    int? status,
  }) async {
    final companion = LocalConversationsCompanion(
      conversID: Value(conversID),
      lastMessage: Value(preview.length > 200 ? preview.substring(0, 200) : preview),
      lastMessageAt: Value(at),
      lastMessageType: Value(type),
      lastMessageSenderID:
          senderID != null ? Value(senderID) : const Value.absent(),
      lastMessageStatus: status != null ? Value(status) : const Value.absent(),
    );
    await _db.into(_db.localConversations).insertOnConflictUpdate(companion);
    if (fromOther) {
      // Only increment unread if the conversation is not currently active.
      if (conversID != _activeConversationID) {
        await _db.transaction(() async {
          final current = await (_db.select(_db.localConversations)
                ..where((c) => c.conversID.equals(conversID)))
              .getSingleOrNull();
          await _dao.setUnread(conversID, (current?.unreadCount ?? 0) + 1);
        });
      }
    }
  }

  LocalConversationsCompanion _convToCompanion(Conversation c, Map<String, dynamic> raw) {
    return LocalConversationsCompanion(
      conversID: Value(c.conversID),
      isGroup: Value(c.isGroup),
      groupName: Value(c.groupName),
      groupPhoto: Value(c.groupPhoto),
      lastMessage: Value(c.lastMessage),
      lastMessageAt: Value(_parseDate(c.lastMessageAt)),
      lastMessageSenderID: Value(c.lastMessageSenderID),
      lastMessageType: Value(c.lastMessageType),
      lastMessageStatus: Value(c.lastMessageStatus),
      unreadCount: Value(c.unreadCount),
      isPinned: Value(c.isPinned),
      isArchived: Value(c.isArchived),
      participantsJson: Value(encodeParticipants(raw['participants'] as List? ?? [])),
    );
  }

  LocalMessagesCompanion _msgJsonToCompanion(Map<String, dynamic> j) {
    final clientId = j['clientId']?.toString() ?? 'srv_${_toInt(j['msgID'])}';
    return LocalMessagesCompanion(
      clientId: Value(clientId),
      msgID: Value(_toInt(j['msgID'])),
      conversationID: Value(_toInt(j['conversationID'])),
      senderID: Value(_toInt(j['senderID'])),
      content: Value(j['content']?.toString()),
      type: Value(_toInt(j['type'])),
      status: Value(_toInt(j['status'], fallback: 1)),
      sendAt: Value(_parseDate(j['sendAt']) ?? DateTime.now()),
      deliveredAt: Value(_parseDate(j['deliveredAt'])),
      readAt: Value(_parseDate(j['readAt'])),
      mediaUrl: Value(j['mediaUrl']?.toString()),
      mediaName: Value(j['mediaName']?.toString()),
      mediaDuration: Value(j['mediaDuration'] == null ? null : _toInt(j['mediaDuration'])),
      // `Value.absent()` si absent (et non `Value(null)`) : un resync qui ne
      // reçoit pas d'enveloppe (déchiffrement déjà consommé, ou message
      // texte) ne doit jamais effacer une enveloppe déjà stockée pour cette
      // ligne — `insertOnConflictUpdate` laisse la colonne intacte.
      mediaEnvelope: j.containsKey('mediaEnvelope')
          ? Value(j['mediaEnvelope']?.toString())
          : const Value.absent(),
      replyToID: Value(j['replyToID'] == null ? null : _toInt(j['replyToID'])),
      replyToContent: Value(j['replyToContent']?.toString()),
      isEdited: Value(j['isEdited'] == 1 || j['isEdited'] == true),
      editedAt: Value(_parseDate(j['editedAt'])),
      isDeleted: Value(j['isDeleted'] == 1 || j['isDeleted'] == true),
      deletedForID: Value(j['deletedForID'] == null ? null : _toInt(j['deletedForID'])),
      isStatusReply: Value(_toInt(j['isStatusReply'])),
      senderNom: Value(j['sender_nom']?.toString()),
      senderPseudo: Value(j['sender_pseudo']?.toString()),
      senderAvatar: Value(j['sender_avatar']?.toString()),
      syncPending: const Value(false),
      lastEmittedAt: const Value(null),
    );
  }

  String _newClientId() =>
      'c_${_myId}_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}';

  static int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }
}
