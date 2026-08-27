/// Règles pures du journal d'appels : curseur de pagination, exclusion mutuelle
/// des chargements, et sens de l'appel. Extraites pour tests unitaires.
library;

/// Sens d'un appel dans le journal.
enum CallDirection { incoming, outgoing, missed }

/// True si le curseur `before` doit accompagner la requête.
///
/// Le garde d'origine était `before > 0`, ce qui confond un `idCall` valant 0
/// avec « pas de curseur ». Or `Call.fromJson` défaute à 0 sur une ligne sans
/// `IDcall` : le paramètre était alors omis, le serveur renvoyait la première
/// page, `_hasMore` ne passait jamais à faux, et l'écran redemandait la même
/// page à chaque défilement.
///
/// Le serveur sait déjà gérer un curseur inconnu — il renvoie une page vide
/// « plutôt que de renvoyer à nouveau la page 1 ». Lui transmettre le curseur
/// tel quel, c'est lui laisser appliquer cette protection.
bool sendsCursor(int? before) => before != null;

/// True si une page suivante peut être demandée maintenant.
///
/// `_loadMoreCalls` ne s'excluait que sur `_isLoading`, or `_loadRecentCalls` ne
/// pose ce drapeau que si le cache local est vide : les deux pouvaient donc
/// écrire `_hasMore` en même temps, et le rafraîchissement — plus lent — le
/// remettait à vrai après que le chargement de page eut détecté la fin.
bool canLoadMorePage({
  required bool isLoadingMore,
  required bool isLoading,
  required bool isRefreshing,
  required bool hasMore,
  required bool hasCalls,
}) {
  if (isLoadingMore || isLoading || isRefreshing) return false;
  if (!hasMore) return false;
  return hasCalls;
}

/// Sens d'un appel, pour l'icône du journal.
///
/// L'affichage ne distinguait que « manqué » et « le reste » : la flèche
/// sortante s'affichait donc pour tout appel reçu et décroché. L'information
/// était pourtant déjà calculée deux lignes plus haut, pour déterminer quel
/// interlocuteur afficher.
CallDirection callDirection({
  required bool isMissed,
  required bool isIncoming,
}) {
  if (isMissed) return CallDirection.missed;
  return isIncoming ? CallDirection.incoming : CallDirection.outgoing;
}
