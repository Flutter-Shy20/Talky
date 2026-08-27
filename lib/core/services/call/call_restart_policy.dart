/// Helpers purs décidant *quand* une offre de reprise ICE peut partir, et
/// laquelle accepter. Extraits pour tests unitaires sans CallService complet.
///
/// Ces deux décisions ont une raison d'être commune : une offre de reprise
/// repart d'une génération neuve, ce qui purge les candidats ICE en vol et
/// périme ceux que le pair envoie encore. Deux offres coup sur coup ne
/// réparent donc pas l'appel, elles le condamnent — le pair répond à celle
/// qu'il a traitée, notre compteur a déjà avancé, et la garde anti-périmé jette
/// la seule réponse utile.
library;

/// True si une nouvelle offre de reprise peut partir maintenant.
///
/// [lastOfferAt] est le moment de la dernière offre réellement émise (null si
/// aucune), [window] le temps laissé à une offre pour être répondue.
bool canEmitRestartOffer({
  required DateTime? lastOfferAt,
  required DateTime now,
  required Duration window,
}) {
  if (lastOfferAt == null) return true;
  return now.difference(lastOfferAt) >= window;
}

/// Fenêtre pendant laquelle un snapshot sans identifiant serveur peut encore
/// valoir pour la reprise qu'on reçoit.
///
/// Le snapshot vit deux heures ; la preuve de fin, elle, ne vit que deux
/// minutes. Accepter un snapshot muet au-delà revient à faire confiance à un
/// appel dont plus rien ne dit s'il est terminé.
const Duration outgoingSnapshotWildcardWindow = Duration(minutes: 2);

/// True si le snapshot d'appel sortant correspond bien à la reprise reçue.
///
/// L'appariement se faisait sur le seul `remoteUserId`, avec un joker : un
/// `serverCallId` absent ou vide était accepté quel que soit l'identifiant de
/// la reprise. Un snapshot d'un appel précédent vers la même personne validait
/// donc une reprise portant un autre appel — et il vit deux heures, n'est
/// effacé que dans `_terminateCall` (donc jamais si le process meurt), et deux
/// chemins en laissent délibérément un orphelin.
///
/// Le joker reste — un sortant tué avant `call_answered` n'a jamais connu son
/// identifiant serveur — mais il est borné dans le temps.
bool snapshotMatchesResume({
  required String? snapServerCallId,
  required String snapClientCallId,
  required int snapPeerId,
  required int snapStartedAtMs,
  required String eventCallId,
  required int eventPeerId,
  required int nowMs,
  Duration wildcardWindow = outgoingSnapshotWildcardWindow,
}) {
  if (snapPeerId != eventPeerId) return false;
  if (snapServerCallId == eventCallId) return true;
  if (snapClientCallId == eventCallId) return true;

  final knowsItsServerId =
      snapServerCallId != null && snapServerCallId.isNotEmpty;
  if (knowsItsServerId) return false;

  final age = nowMs - snapStartedAtMs;
  return age >= 0 && age <= wildcardWindow.inMilliseconds;
}

/// True si une offre de reprise reçue est plus ancienne que la négociation en
/// cours et doit être ignorée.
///
/// Une génération absente signifie « client sans compteur » : on accepte, comme
/// le fait le relais ICE.
bool isStaleRejoinOffer({
  required int? offerGeneration,
  required int localGeneration,
}) {
  if (offerGeneration == null) return false;
  return offerGeneration < localGeneration;
}
