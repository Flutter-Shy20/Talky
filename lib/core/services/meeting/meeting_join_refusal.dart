/// Pourquoi une tentative d'entrée en réunion a échoué.
///
/// Les refus arrivent de trois endroits et sous trois formes : un
/// `StateError` posé localement quand un appel tient déjà la session média, un
/// `StateError` portant le code d'un `meeting:join_denied`, et une exception
/// HTTP dont le message est déjà une phrase du serveur. Sans classement, le
/// lobby affichait « Bad state: SESSION_BUSY » à l'utilisateur.
library;

import '../../../talky_api_client.dart' show TalkyException;

/// Les refus qu'on sait nommer. `autre` couvre tout le reste — réseau,
/// permission, erreur serveur — et part désormais au presenter, qui choisit un
/// texte prévu. Auparavant cette branche réaffichait le message d'origine, au
/// motif qu'il était « plus précis » : en pratique c'était de la prose serveur
/// non traduite, ou l'exception `getUserMedia` d'une caméra occupée.
enum MeetingJoinRefusal {
  /// Un appel est en cours : la session média ne peut pas être partagée.
  sessionOccupee,

  /// L'organisateur a mis fin à la réunion.
  reunionTerminee,

  /// L'heure de fin est passée, sans que personne l'ait terminée.
  reunionEchue,

  /// Le compte ne figure pas parmi les participants.
  nonInvite,

  /// Tout le reste : on retombe sur le message d'origine.
  autre,
}

/// Classe une erreur d'entrée en réunion.
///
/// Le `code` d'une [TalkyException] fait foi quand il existe. À défaut, on
/// retombe sur la chaîne : les refus locaux et les `meeting:join_denied`
/// voyagent encore dans le message d'un `StateError`, faute d'un type dédié.
/// Cette seconde voie est un pis-aller, pas le contrat — d'où l'ordre.
MeetingJoinRefusal refusPourErreur(Object? erreur) {
  if (erreur == null) return MeetingJoinRefusal.autre;

  final code = erreur is TalkyException ? erreur.code : null;
  final indice = code ?? erreur.toString();

  if (indice.contains('SESSION_BUSY')) return MeetingJoinRefusal.sessionOccupee;
  if (indice.contains('MEETING_ENDED')) return MeetingJoinRefusal.reunionTerminee;
  if (indice.contains('MEETING_EXPIRED')) return MeetingJoinRefusal.reunionEchue;
  if (indice.contains('NOT_A_PARTICIPANT')) return MeetingJoinRefusal.nonInvite;
  return MeetingJoinRefusal.autre;
}
