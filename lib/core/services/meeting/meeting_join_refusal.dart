/// Pourquoi une tentative d'entrée en réunion a échoué.
///
/// Les refus arrivent de trois endroits et sous trois formes : un
/// `StateError` posé localement quand un appel tient déjà la session média, un
/// `StateError` portant le code d'un `meeting:join_denied`, et une exception
/// HTTP dont le message est déjà une phrase du serveur. Sans classement, le
/// lobby affichait « Bad state: SESSION_BUSY » à l'utilisateur.
library;

/// Les refus qu'on sait nommer. `autre` couvre tout le reste — réseau,
/// permission, erreur serveur —, pour lequel le message d'origine est plus
/// informatif que n'importe quelle reformulation.
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
/// Le rapprochement se fait sur la chaîne plutôt que sur un type : les codes
/// voyagent dans le message d'un `StateError` (`SESSION_BUSY`, ou le `code` du
/// `meeting:join_denied`), et rien ne garantit qu'ils garderont ce véhicule.
/// Une erreur HTTP, elle, porte déjà la phrase du serveur — elle tombe dans
/// `autre`, et c'est voulu.
MeetingJoinRefusal refusPourErreur(Object? erreur) {
  if (erreur == null) return MeetingJoinRefusal.autre;
  final texte = erreur.toString();
  if (texte.contains('SESSION_BUSY')) return MeetingJoinRefusal.sessionOccupee;
  if (texte.contains('MEETING_ENDED')) return MeetingJoinRefusal.reunionTerminee;
  if (texte.contains('MEETING_EXPIRED')) return MeetingJoinRefusal.reunionEchue;
  if (texte.contains('NOT_A_PARTICIPANT')) return MeetingJoinRefusal.nonInvite;
  return MeetingJoinRefusal.autre;
}
