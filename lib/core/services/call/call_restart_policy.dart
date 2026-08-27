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
