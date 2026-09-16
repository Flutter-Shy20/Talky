/// Helpers purs pour le routage cold-start / merge / ready des conférences.
/// Extraite pour tests unitaires sans CallService complet.

/// True si l'appel entrant est une invitation conférence (join/transfer).
bool isConferenceCallIncoming({
  String? sessionKind,
  String? callId,
  String? roomId,
}) {
  if (sessionKind == 'conference') return true;
  if (callId != null && callId.startsWith('conf_')) return true;
  if (roomId != null && roomId.startsWith('conf_')) return true;
  return false;
}

/// Genre de session que désigne une acceptation venue d'un push.
enum AcceptedSessionKind { unAUn, groupe, conference }

/// Que faut-il établir quand l'utilisateur décroche depuis une notification ?
///
/// `acceptIncomingCallFromPush` traitait la conférence, puis laissait **tout le
/// reste** tomber dans la queue du 1-à-1 : armer l'auto-réponse et attendre une
/// offre WebRTC. Or un appel de groupe n'en produit aucune — le code le savait
/// même, puisqu'il évitait d'armer le délai d'attente d'offre « le groupe
/// n'utilise pas `_pendingOffer` ». Mais rien ne prenait le relais.
///
/// Résultat : décrocher un appel de groupe depuis la notification ne pouvait
/// **pas** aboutir. `joinGroupCall` n'a qu'un appelant dans toute l'application,
/// le bouton de l'écran entrant. L'appel restait en « entrant » jusqu'à ce que
/// le filet de 55 secondes le refuse.
AcceptedSessionKind acceptedSessionKind({
  required bool isConference,
  String? roomId,
}) {
  if (isConference) return AcceptedSessionKind.conference;
  final salon = roomId?.trim() ?? '';
  return salon.isEmpty ? AcceptedSessionKind.unAUn : AcceptedSessionKind.groupe;
}

/// True si call_conf_invite doit être fusionné (même session déjà incoming).
bool shouldMergeConfInvite({
  required String callStatusName,
  String? confSessionId,
  String? currentCallId,
  required String incomingSessionId,
}) {
  if (callStatusName != 'incoming') return false;
  return confSessionId == incomingSessionId || currentCallId == incomingSessionId;
}

/// True si l'écran d'appel en cours peut être ouvert après une acceptation.
///
/// Les branches groupe et conférence poussaient l'écran inconditionnellement,
/// alors que `joinGroupCall` et `acceptConferenceInvite` avalent leurs erreurs et
/// repassent en `idle` ; seule la branche 1-à-1 vérifiait. Et l'écran d'appel n'a
/// aucune garde sur `idle` : son écouteur n'est branché qu'après deux
/// `initialize()` asynchrones, donc le passage à `idle` est déjà passé. On
/// obtenait un « appel en cours » à 00:00, sans média, sans erreur affichée et
/// sans fermeture automatique.
bool shouldOpenOngoingScreen({
  required String callStatusName,
  String? errorMessage,
}) {
  if (errorMessage != null && errorMessage.isNotEmpty) return false;
  return callStatusName != 'idle' && callStatusName != 'ended';
}

/// Participants à afficher dans la grille d'une session à trois.
///
/// La grille itérait sur les flux distants : un participant entré mais dont la
/// PeerConnection n'a pas encore reçu de piste n'avait aucune tuile, alors que le
/// roster le connaît — et le compte affiché était faux d'autant. On part donc du
/// roster, en gardant l'ordre des flux pour ceux qui en ont déjà un.
List<String> conferenceTileIds({
  required Iterable<String> rosterIds,
  required Iterable<String> streamIds,
  String? myRosterId,
}) {
  final roster = rosterIds.where((id) => id != myRosterId).toSet();
  final ordered = <String>[
    for (final id in streamIds)
      if (roster.contains(id)) id,
  ];
  for (final id in roster) {
    if (!ordered.contains(id)) ordered.add(id);
  }
  return ordered;
}

/// Clé idempotente pour call_conf_ready (sessionId|peerId).
String confReadyKey(String sessionId, String peerId) => '$sessionId|$peerId';

/// Ce que la bascule à trois fait de la connexion 1-à-1 d'origine.
enum OriginLinkRole {
  /// Premier ajout : elle devient le premier lien du maillage, surveillée.
  verser,

  /// Rebascule, et c'est encore elle qui porte le lien : surveillée seulement.
  surveiller,

  /// Rebascule, le lien passe par une autre connexion : on n'y touche pas.
  ignorer,
}

/// Rôle de la connexion d'origine quand un appel à deux passe à trois.
///
/// Au premier ajout, rien n'existe encore dans le maillage : la connexion
/// 1-à-1 y est versée. Retombé à deux puis rebasculé, le lien vers l'autre y
/// est déjà. S'il passe par une autre connexion, celle d'origine est fermée
/// (son pair est parti) ou n'a jamais été négociée (l'ancien invité en a une,
/// créée par `_initLocalStream`) : la verser écraserait le lien vivant, et la
/// surveiller ferait retirer ce pair au premier `Closed` d'une connexion morte.
OriginLinkRole originLinkRole({
  required bool meshLinkExists,
  required bool meshLinkIsOrigin,
}) {
  if (!meshLinkExists) return OriginLinkRole.verser;
  return meshLinkIsOrigin ? OriginLinkRole.surveiller : OriginLinkRole.ignorer;
}

/// Salle à annoncer au serveur pour la signalisation du maillage.
///
/// Retombé à deux dans une session, `_groupRoomId` est nul : le serveur, qui
/// garde ce relais par la session, jetait alors offres, réponses et candidats.
/// Après un transfert, le lien survivant est maillé : son redémarrage ICE se
/// perdait, et il tombait au premier trou réseau.
String? meshSignalRoomId(String? groupRoomId, String? confSessionId) =>
    groupRoomId ?? confSessionId;

/// Un refus d'ajout remet-il à zéro l'état du tour d'invitation ?
///
/// Seulement si aucune invitation n'est en vol. Quand les deux appuient en même
/// temps, le perdant peut recevoir le `call_add_pending` du gagnant avant son
/// propre `call_add_rejected` : le tour qu'il voit est alors celui du gagnant,
/// et y effacer la cible d'un transfert ferait expirer ce transfert.
bool addRejectedResetsRound({required bool hasPendingInvitee}) =>
    !hasPendingInvitee;

/// Le bouton « Ajouter à l'appel » — et « Transférer » — est-il proposé ?
///
/// Le droit est rendu dès qu'on retombe à deux (docs/transfert_appel.md
/// § 4.5), y compris dans une session où quelqu'un est déjà passé : c'est ce
/// qui rend le transfert en cascade possible. Il manque tant qu'une invitation
/// est en vol ou que la grille à trois est affichée. Le serveur tranche en
/// dernier ressort.
bool canAddToCall({
  required String callStatusName,
  required bool hasConfSession,
  required bool showsGroupRoom,
  required bool hasPendingInvitee,
  required bool hasRemoteUser,
  required bool meetingActive,
}) {
  // `hasConfSession` n'y entre pas, et c'est tout le changement : la session
  // survit au retour à deux et ne retire plus le droit.
  return callStatusName == 'connected' &&
      !showsGroupRoom &&
      !hasPendingInvitee &&
      hasRemoteUser &&
      !meetingActive;
}

/// Après l'échec d'une invitation, la session continue-t-elle ?
///
/// Le serveur la garde dès que quelqu'un y est entré : elle porte l'appel, et
/// raccrocher doit continuer d'y passer. Un serveur plus ancien n'envoie pas ce
/// drapeau : comportement d'avant, la session est oubliée.
bool confFailedKeepsSession(Map data) {
  final v = data['keepSession'];
  return v == true || v?.toString() == 'true';
}

/// Identifiant de l'invitation portée par [data], s'il y en a un.
///
/// Le serveur en donne un par invitation : le `sessionId` à la première,
/// `…_r<n>` ensuite ; un serveur plus ancien n'en envoie pas. C'est lui que ce
/// téléphone présente à CallKit et marque terminé — réinvité dans une session
/// qu'il a quittée, il ne tombe pas sur la marque de son départ.
String? conferenceInviteId(Map data) {
  final id = data['inviteId']?.toString();
  return (id == null || id.isEmpty) ? null : id;
}

/// Identifiant qu'un `call_ended` vise sur ce téléphone.
///
/// Adressé à un invité, il porte aussi l'identifiant de son invitation, le
/// seul que son CallKit connaisse ; les autres destinataires n'ont que
/// `callId`.
String? endedCallId(Map data) =>
    conferenceInviteId(data) ?? data['callId']?.toString();

/// Décide si un ready peut être mis en file / émis côté client restant.
///
/// [transferTargetId] = C (cible du transfert). Sans match exact, aucun ready :
/// évite d'armer le leaveTimer serveur sur une PC A↔B déjà connected.
bool canLocalEmitConfReady({
  required String confMode,
  required bool isTransferInitiator,
  required bool isConfInvitee,
  required String peerId,
  int? localUserId,
  String? transferTargetId,
}) {
  if (confMode != 'transfer') return false;
  if (isTransferInitiator) return false;
  if (isConfInvitee) return false;
  if (localUserId != null && peerId == localUserId.toString()) return false;
  if (transferTargetId == null || transferTargetId.isEmpty) return false;
  if (peerId != transferTargetId) return false;
  return true;
}

/// Décide si un join/ready en file doit être droppé au flush.
enum ConfQueueFlushResult { emit, drop, keep }

ConfQueueFlushResult confJoinFlushDecision({
  required String? pendingSessionId,
  required String? confSessionId,
  required bool isTerminal,
  required String callStatusName,
  required bool socketReady,
}) {
  if (pendingSessionId == null) return ConfQueueFlushResult.drop;
  if (confSessionId != pendingSessionId) return ConfQueueFlushResult.drop;
  if (isTerminal) return ConfQueueFlushResult.drop;
  if (callStatusName != 'joining' &&
      callStatusName != 'incoming' &&
      callStatusName != 'connected') {
    return ConfQueueFlushResult.drop;
  }
  if (!socketReady) return ConfQueueFlushResult.keep;
  return ConfQueueFlushResult.emit;
}

ConfQueueFlushResult confReadyFlushDecision({
  required String keySessionId,
  required String? confSessionId,
  required bool isTerminal,
  required String confMode,
  required bool isTransferInitiator,
  required String callStatusName,
  required bool socketReady,
}) {
  if (confSessionId != keySessionId) return ConfQueueFlushResult.drop;
  if (isTerminal) return ConfQueueFlushResult.drop;
  if (confMode != 'transfer' || isTransferInitiator) {
    return ConfQueueFlushResult.drop;
  }
  if (callStatusName != 'connected' &&
      callStatusName != 'joining' &&
      callStatusName != 'incoming') {
    return ConfQueueFlushResult.drop;
  }
  if (!socketReady) return ConfQueueFlushResult.keep;
  return ConfQueueFlushResult.emit;
}

/// Ce départ annoncé par le serveur est-il le mien ?
///
/// `call_conf_left` n'était émis que vers les restants : celui que le serveur
/// retirait — grâce de déconnexion expirée alors qu'il était revenu, reprise
/// refusée — n'apprenait rien. Son écran d'appel restait ouvert sur une
/// conférence dont il ne faisait plus partie. Il reçoit désormais le sien, et
/// c'est à cela qu'il le reconnaît.
///
/// Le `call_ended` qui l'accompagne ne suffit pas : pendant une conférence
/// encore peuplée, l'app l'ignore délibérément — garde contre les `call_ended`
/// parasites —, et le partant a justement encore ses liens ouverts.
///
/// Sans identité de roster, rien ne me vise : conclure « oui » en comparant
/// deux inconnues raccrocherait l'appel de tout le monde.
bool confLeftMeVise({required String? leftUserId, required String? myRosterId}) {
  final parti = leftUserId?.trim() ?? '';
  final moi = myRosterId?.trim() ?? '';
  if (parti.isEmpty || moi.isEmpty) return false;
  return parti == moi;
}
