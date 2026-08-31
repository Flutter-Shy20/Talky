/// Contraintes SDP d'une offre de redémarrage ICE.
///
/// `flutter_webrtc` transmet la map telle quelle au natif, qui la lit avec
/// `MediaConstraintsUtils.parseMediaConstraints` — lequel ne regarde QUE les
/// clés `mandatory` et `optional`. Une map plate comme `{'iceRestart': true}`
/// produit donc des contraintes **vides**, sans le moindre avertissement :
/// l'offre part avec le même ufrag ICE, le pair y répond normalement, et rien
/// ne redémarre. Aucun nouveau candidat n'est collecté, la session ICE reste
/// morte, et l'appel meurt au bout du délai global après trois tentatives qui
/// n'en étaient pas.
///
/// La clé native porte une majuscule : `IceRestart`, pas `iceRestart`.
///
/// `OfferToReceive*` est repris du défaut du plugin (`defaultSdpConstraints`),
/// que l'offre initiale utilise faute d'argument. Les omettre ici ferait partir
/// une offre de reprise avec des directions différentes de l'offre d'origine.
library;

const Map<String, dynamic> iceRestartOfferConstraints = {
  'mandatory': {
    'IceRestart': true,
    'OfferToReceiveAudio': true,
    'OfferToReceiveVideo': true,
  },
  'optional': <dynamic>[],
};
