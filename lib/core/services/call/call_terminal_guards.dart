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
  final kit = callKitCallId?.trim();
  if (kit != null && kit.isNotEmpty) return kit;
  final courant = currentCallId?.trim();
  if (courant != null && courant.isNotEmpty) return courant;
  return null;
}

/// Le statut local autorise-t-il à confirmer une reprise d'appel ?
///
/// `incoming` en fait partie, et son absence coûtait cher : au démarrage à
/// froid sur un appel déjà en communication, le point d'entrée CallKit repose
/// l'état à `incoming` en armant l'auto-réponse — le serveur, lui, n'envoie plus
/// `incoming_call` mais `call_resume`. Le statut n'étant pas reconnu, le client
/// répondait `call_resume_reject`, c'est-à-dire qu'il demandait lui-même au
/// serveur de raccrocher un appel parfaitement vivant. L'application tuée puis
/// rouverte en pleine conversation coupait donc la communication des deux côtés.
bool acceptsResumeForLocalStatus({
  required String callStatusName,
  bool awaitingAutoAnswer = false,
}) {
  switch (callStatusName) {
    case 'connecting':
    case 'connected':
    case 'reconnecting':
    case 'outgoing':
      return true;
    case 'incoming':
      // Seulement si une entrée CallKit acceptée nous a remis dans cet état :
      // un entrant qui sonne encore n'a rien à reprendre.
      return awaitingAutoAnswer;
    default:
      return false;
  }
}

/// Faut-il reconstruire le socket pendant qu'un appel est en reconnexion ?
///
/// Un socket peut être mort sans que rien ne le dise : le TCP est tombé, mais
/// Socket.IO ne le constate qu'au bout de son ping — 25 s d'intervalle, 20 s de
/// patience. Pendant ces quarante-cinq secondes, `isSocketReady` répond `true`,
/// les offres de reprise partent dans le vide, et l'appel reste sur
/// « Reconnexion… » jusqu'au délai global, où il se coupe tout seul. C'est le
/// symptôme exact rapporté sur les appels longs — plus l'appel dure, plus la
/// connexion a de temps pour mourir sans le dire.
///
/// Le signal retenu est le **silence** : pendant une reconnexion, le socket est
/// normalement le canal le plus bavard qui soit — candidats ICE, offres et
/// réponses de reprise. S'il n'a plus rien apporté depuis [silenceThreshold],
/// il ne sert plus à rien et le démonter ne coûte rien. À l'inverse, un socket
/// qui livre encore des événements est peut-être notre seule chance de reprise :
/// on n'y touche pas, même si le média, lui, est à terre.
///
/// **Une seule fois par épisode.** Reconstruire en boucle relancerait la
/// signalisation toutes les huit secondes et aucune négociation n'aurait jamais
/// le temps d'aboutir.
bool shouldRebuildSocketDuringReconnect({
  required bool stillReconnecting,
  required bool alreadyRebuilt,
  required Duration? sinceLastSocketEvent,
  required Duration silenceThreshold,
}) {
  if (!stillReconnecting || alreadyRebuilt) return false;
  // Jamais rien reçu : il n'y a rien à préserver.
  if (sinceLastSocketEvent == null) return true;
  return sinceLastSocketEvent >= silenceThreshold;
}

/// L'application est-elle au premier plan ?
///
/// [lifecycleStateName] est `WidgetsBinding.instance.lifecycleState?.name`, et
/// `null` signifie qu'**aucun événement de cycle de vie n'est encore arrivé**.
/// Le getter rendait alors `true`, en traitant cet inconnu comme un premier
/// plan. C'est précisément le cas d'un réveil par push derrière l'écran
/// verrouillé : l'application revendiquait la présentation Flutter et lançait
/// sa propre sonnerie pendant que la notification CallKit sonnait nativement.
/// Une des causes directes des doubles sonneries et des doubles écrans.
///
/// L'inconnu est donc traité comme un arrière-plan : c'est CallKit qui
/// présente, et il rendra la main dès que l'accueil sera monté. Le prix est une
/// courte fenêtre au lancement normal où un appel serait présenté par CallKit
/// plutôt que par l'écran Flutter — l'accueil bascule aussitôt.
///
/// La chaîne est passée en nom plutôt qu'en `AppLifecycleState` pour garder ce
/// fichier sans dépendance à Flutter, comme le reste de ses gardes.
bool appIsForeground(String? lifecycleStateName) =>
    lifecycleStateName == 'resumed';

/// Une invitation de groupe est-elle assez complète pour être présentée ?
///
/// Sans identifiant de salon, il n'y a rien à présenter et rien à rejoindre —
/// mais poser quand même le statut « entrant » suffisait à **rendre l'appareil
/// sourd** : la revendication de présentation était refusée faute
/// d'identifiant, aucune interface ne s'ouvrait, aucun filet temporel n'était
/// armé, et tous les points d'entrée refusent un entrant tant que le statut
/// n'est pas `idle`. Plus aucun appel ne pouvait arriver, et la seule sortie
/// était un `call_ended` de forme 1-à-1 venu du serveur.
///
/// La règle générale dont ceci est un cas : ne jamais poser un statut dont
/// aucune horloge locale ne peut répondre.
bool groupInviteIsPresentable(String? roomId) =>
    (roomId?.trim() ?? '').isNotEmpty;

/// Sous quel identifiant un appel entrant est-il présenté ?
///
/// Un appel à deux porte un `callId` ; une invitation de groupe n'en a pas — le
/// handler `group_call_invite` ne pose que `_groupRoomId`. Tout code qui vise
/// l'entrant par son seul `callId` sort donc **à vide** pour un groupe, sans un
/// mot.
///
/// C'est ce qui produisait les deux sonneries : le retrait de l'entrée CallKit
/// visait `_currentCallId`, nul, et ne retirait rien ; la sonnerie Flutter,
/// elle, raisonnait sur le salon et partait bien. Les deux moitiés du même geste
/// ne parlaient pas du même appel.
String? incomingPresentationId({String? callId, String? groupRoomId}) {
  final id = callId?.trim();
  if (id != null && id.isNotEmpty) return id;
  final salon = groupRoomId?.trim();
  if (salon != null && salon.isNotEmpty) return salon;
  return null;
}
