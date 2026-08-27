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
