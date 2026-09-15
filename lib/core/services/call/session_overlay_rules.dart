/// Ce qui se montre au-dessus de l'application quand une session est minimisée :
/// le bandeau compact, la fenêtre vidéo, ou rien. Logique pure, testable.
library;

/// Les deux surfaces peuvent coexister, et c'est voulu.
///
/// Un bandeau unique servait trois sujets — appel, réunion, lecture d'un vocal
/// — et ne pouvait donc en montrer qu'un. Rendre la vidéo à une fenêtre libère
/// le bandeau : écouter un vocal pendant un appel vidéo minimisé affiche
/// désormais les deux, là où le vocal disparaissait derrière l'appel.
typedef SessionOverlays = ({bool banner, bool videoWindow});

/// Décide des surfaces à afficher.
///
/// L'ordre de priorité reprend celui d'avant : un appel actif l'emporte sur une
/// réunion, et la lecture vocale ne s'affiche que si elle a la place. La seule
/// règle neuve est le partage entre les deux surfaces — **la vidéo va à la
/// fenêtre, le reste au bandeau**.
///
/// Une session n'occupe une surface que **minimisée** : tant que son écran
/// plein est ouvert, elle est déjà entièrement visible.
SessionOverlays sessionOverlays({
  required bool callActive,
  required bool callMinimized,
  required bool callIsVideo,
  required bool meetingActive,
  required bool meetingMinimized,
  required bool meetingIsVideo,
  required bool voicePlaying,
}) {
  final callShows = callActive && callMinimized;
  // Une réunion ne prend la main que si aucun appel n'est en cours — un appel
  // et une réunion simultanés ne devraient pas exister, mais la garde était
  // déjà là et rien ne justifie de la retirer au passage.
  final meetingShows = !callActive && meetingActive && meetingMinimized;

  final videoWindow =
      (callShows && callIsVideo) || (meetingShows && meetingIsVideo);

  final sessionNeedsBanner =
      (callShows && !callIsVideo) || (meetingShows && !meetingIsVideo);

  return (
    banner: sessionNeedsBanner || voicePlaying,
    videoWindow: videoWindow,
  );
}
