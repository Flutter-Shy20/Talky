/// Helpers purs décidant si un événement reçu du serveur concerne bien l'appel
/// en cours. Extraits pour tests unitaires sans CallService complet.
///
/// Le serveur émet ses événements terminaux depuis une douzaine d'endroits —
/// fin, refus, grâce de déconnexion, `resume_ack_timeout`, transfert — et rien
/// ne garantit qu'ils arrivent avant que l'appel suivant ait commencé. Sans
/// garde, un événement en retard raccroche un appel auquel il ne se rapportait
/// pas. Le modèle de référence est `call_busy` / `call_no_answer`, qui vérifient
/// depuis toujours le statut avant d'agir.
library;

/// True si ce statut décrit un appel encore vivant.
///
/// `reconnecting` en fait partie : l'appel n'est pas perdu, il se rétablit.
/// L'omettre faisait disparaître la bannière d'appel minimisé et rendait
/// l'écran impossible à rouvrir pendant toute la reconnexion — au moment
/// précis où l'utilisateur veut voir ce qui se passe.
bool isActiveCallStatus(String callStatusName) {
  switch (callStatusName) {
    case 'outgoing':
    case 'connecting':
    case 'connected':
    case 'reconnecting':
    case 'joining':
      return true;
    default:
      return false;
  }
}

/// `call_ended` ordinaire : ne termine que l'appel qu'il désigne.
///
/// Un identifiant absent vaut acceptation — c'est le comportement historique,
/// et certains chemins serveur n'en portent pas.
bool endsCurrentCall({
  required String? eventCallId,
  String? currentCallId,
  String? confSessionId,
  String? groupRoomId,
}) {
  if (eventCallId == null || eventCallId.isEmpty) return true;
  return eventCallId == currentCallId ||
      eventCallId == confSessionId ||
      eventCallId == groupRoomId;
}

/// `call_rejected`, `call_failed`, `call_error` : événements terminaux d'un
/// appel **sortant**. Ils n'ont de sens que pendant qu'on en passe un, et que
/// pour celui-là.
bool acceptsOutgoingTerminalEvent({
  required String callStatusName,
  String? eventCallId,
  String? currentCallId,
}) {
  if (callStatusName != 'outgoing' && callStatusName != 'connecting') {
    return false;
  }
  if (eventCallId == null || eventCallId.isEmpty) return true;
  return currentCallId == null ||
      currentCallId.isEmpty ||
      eventCallId == currentCallId;
}

/// `group_call_ended` : ne démonte le maillage que s'il désigne la salle où
/// l'on se trouve, et seulement si l'on y est encore.
bool endsGroupCall({
  required String? groupRoomId,
  String? eventRoomId,
  required String callStatusName,
}) {
  if (groupRoomId == null || groupRoomId.isEmpty) return false;
  if (callStatusName == 'idle' || callStatusName == 'ended') return false;
  if (eventRoomId == null || eventRoomId.isEmpty) return true;
  return eventRoomId == groupRoomId;
}

/// Rôle de restart après une reprise.
///
/// `call_resume` porte déjà le bon rôle — `entry.lastAnswer != null ? 'caller'
/// : 'callee'` — mais il n'était jamais lu : le drapeau était posé à `true`
/// même sur le device qui **reçoit** l'offre de rejoin. Les deux côtés se
/// croyaient alors initiateurs, et le protocole est « caller-only ».
/// Sans rôle transmis, on conserve ce qu'on savait.
bool resolveOutgoingCaller({
  String? serverRole,
  required bool current,
}) {
  if (serverRole == 'caller') return true;
  if (serverRole == 'callee') return false;
  return current;
}

/// Vrai si [candidate] désigne l'appel en cours, quel que soit celui de ses
/// deux identifiants qu'on présente.
///
/// Un appel sortant en porte deux : celui fabriqué localement pour ouvrir la
/// session CallKit, et celui du serveur, adopté au décrochage. CallKit et la
/// couche native ne connaissent que le premier ; le serveur et l'isolate FCM
/// ne parlent que du second. Ne comparer qu'un seul rendait faux, selon le
/// sens, soit la fin d'appel venue du push, soit la restauration après kill.
bool matchesCallIdentity({
  required String? candidate,
  String? currentCallId,
  String? callKitCallId,
}) {
  if (candidate == null || candidate.isEmpty) return false;
  return candidate == currentCallId || candidate == callKitCallId;
}

/// Vrai si [candidate] désigne l'appel sortant encore en cours — la garde de
/// `shouldPreserveOutgoingCallKit` et de `restoreOutgoingFromColdStart`, qui
/// reçoivent toutes deux l'identifiant porté par l'entrée CallKit.
bool matchesActiveOutgoingCall({
  required String? candidate,
  required String callStatusName,
  String? currentCallId,
  String? callKitCallId,
}) {
  if (!matchesCallIdentity(
    candidate: candidate,
    currentCallId: currentCallId,
    callKitCallId: callKitCallId,
  )) {
    return false;
  }
  // `joining` est exclu : c'est une entrée en conférence, pas un sortant 1-à-1
  // dont on aurait un instantané à restaurer.
  return callStatusName == 'outgoing' ||
      callStatusName == 'connecting' ||
      callStatusName == 'connected' ||
      callStatusName == 'reconnecting';
}

/// Vrai s'il faut adopter l'identifiant que le serveur renvoie au décrochage.
///
/// Sans adoption, `_currentCallId` reste l'horodatage fabriqué côté appelant et
/// aucune comparaison avec un événement serveur ne peut aboutir. Un identifiant
/// vide n'apprend rien : on garde le local.
bool shouldAdoptServerCallId({
  required String? serverCallId,
  String? currentCallId,
}) {
  if (serverCallId == null || serverCallId.trim().isEmpty) return false;
  return serverCallId != currentCallId;
}

/// `meeting:ended` : ne termine que la réunion qu'il désigne.
///
/// Le handler ne lisait pas son payload et raccrochait quel que soit le
/// statut. Même famille que `group_call_ended` avant sa garde : un événement
/// tardif — une réunion précédente soldée pendant qu'on vient d'en rejoindre
/// une autre — détruisait le média de celle en cours.
///
/// Un identifiant absent vaut acceptation, comme partout ailleurs ici : le
/// serveur en porte un aujourd'hui, mais une instance plus ancienne peut ne
/// pas le faire.
bool endsCurrentMeeting({
  required Object? currentMeetingId,
  Object? eventMeetingId,
  required String meetingStatusName,
}) {
  if (currentMeetingId == null) return false;
  if (meetingStatusName == 'idle' || meetingStatusName == 'ended') return false;
  final attendu = currentMeetingId.toString();
  if (attendu.isEmpty) return false;
  final recu = eventMeetingId?.toString();
  if (recu == null || recu.isEmpty) return true;
  return recu == attendu;
}


/// Sous quel identifiant enregistrer l'instantané d'un appel sortant.
///
/// C'est celui de CallKit, et pas l'autre. Ses deux lecteurs —
/// `shouldPreserveOutgoingCallKit` et `restoreOutgoingFromColdStart` — reçoivent
/// l'identifiant que porte l'entrée CallKit au démarrage à froid, et le
/// comparent à `clientCallId`.
///
/// Depuis que `_currentCallId` adopte l'identifiant serveur au décrochage,
/// enregistrer `_currentCallId` y écrivait l'identifiant serveur : plus aucune
/// correspondance possible, et un appel vivant voyait sa session CallKit
/// démontée au redémarrage. L'identifiant serveur a son propre champ.
String? outgoingSnapshotIdentity({
  String? callKitCallId,
  String? currentCallId,
}) {
  final courant = currentCallId?.trim();
  if (courant != null && courant.isNotEmpty) return courant;
  return null;
}
