/// Mise en avant d'un participant pendant une réunion.
///
/// Le geste existait côté appel de groupe et pas côté réunion : taper une tuile
/// n'y faisait rien. Ces deux règles sont la part de ce mécanisme qui décide, et
/// la seule qui se teste sans appareil.
library;

/// Le focus survit-il à ce changement de participants ?
///
/// Le participant mis en avant peut partir pendant qu'on le regarde. Sans
/// purge, l'overlay reste ouvert sur un flux mort — et comme le retour arrière
/// est détourné pour fermer le focus, l'écran devient impossible à quitter
/// autrement qu'en raccrochant. C'est le point qu'on oublie en transposant le
/// mécanisme, et le plus désagréable à vivre.
///
/// La tuile locale ne figure jamais dans les flux distants : elle survit
/// toujours. La comparer aux clés distantes la ferait disparaître à la première
/// notification, et se mettre soi-même en avant deviendrait impossible.
///
/// @param focusedId le participant actuellement en avant, ou null
/// @param localId notre propre identifiant, celui qui corrèle socket et WebRTC
/// @param fluxDistants les clés de `remoteStreams`
/// @returns l'identifiant à conserver, ou null pour refermer l'overlay
String? focusEncoreValide({
  required String? focusedId,
  required String? localId,
  required Set<String> fluxDistants,
}) {
  if (focusedId == null) return null;
  if (localId != null && focusedId == localId) return focusedId;
  return fluxDistants.contains(focusedId) ? focusedId : null;
}

/// Ce que le retour arrière doit faire quand on est en réunion.
enum MeetingBackAction {
  /// Refermer la mise en avant, et rester en réunion.
  fermerFocus,

  /// Réduire la réunion en fenêtre — le comportement d'origine de l'écran.
  minimiser,
}

/// Un retour arrière ferme d'abord ce qui est ouvert par-dessus.
///
/// Sans cette distinction, le geste système sortirait de l'écran en laissant
/// croire que le focus l'avait avalé, ou — pire — fermerait la réunion depuis un
/// overlay que l'utilisateur voulait simplement refermer.
MeetingBackAction actionRetour({required bool focusOuvert}) =>
    focusOuvert ? MeetingBackAction.fermerFocus : MeetingBackAction.minimiser;
