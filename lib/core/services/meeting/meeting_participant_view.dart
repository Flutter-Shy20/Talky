/// Ce que le badge d'un participant, dans le détail d'une réunion, doit dire.
library;

/// Les deux états visibles pour un participant : en attente, ou a rejoint.
///
/// `status` en base porte encore un troisième niveau (`2`), mais aucun chemin
/// n'y écrit jamais — voir `migrations/077_participant_status_rejoint.sql`.
/// On ne l'affiche pas séparément : un `2` orphelin retombe sur « en attente »,
/// jamais sur « a rejoint ».
enum MeetingParticipantBadge { enAttente, aRejoint }

/// Ce que le badge annonce pour un participant donné.
///
/// Avant ce correctif, `inviteParticipants` insérait `status = 1` à
/// l'invitation — « accepté » — pour quelqu'un qui n'avait pas encore ouvert
/// l'application. Le badge lisait exactement ce champ : tout invité
/// apparaissait « Accepté », sans rapport avec sa présence réelle.
///
/// `status = 1` veut désormais dire « a rejoint au moins une fois », écrit au
/// premier join réel — pas à l'invitation. L'organisateur est un cas à part :
/// il est inscrit à 1 dès la création, sans quoi son propre détail
/// l'annoncerait « en attente ».
MeetingParticipantBadge badgeParticipant({
  required int status,
  required bool estOrganisateur,
}) {
  if (estOrganisateur) return MeetingParticipantBadge.aRejoint;
  return status == 1
      ? MeetingParticipantBadge.aRejoint
      : MeetingParticipantBadge.enAttente;
}
