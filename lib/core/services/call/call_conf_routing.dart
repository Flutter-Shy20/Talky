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
