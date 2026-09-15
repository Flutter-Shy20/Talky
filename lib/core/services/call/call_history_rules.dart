/// Règles pures du journal d'appels : curseur de pagination, exclusion mutuelle
/// des chargements, et sens de l'appel. Extraites pour tests unitaires.
library;

/// Sens d'un appel dans le journal.
enum CallDirection { incoming, outgoing, missed }

/// True si l'appel a été décroché.
///
/// `status == 1` est le seul témoin d'un décrochage : c'est `answer_call` qui
/// l'écrit côté serveur, avec `start_time`. Tout le reste — 0, 2, 3 — désigne
/// un appel qui n'a jamais abouti.
bool callWasAnswered(int status) => status == 1;

/// True si l'appel n'a jamais abouti : sonnerie sans réponse ou refus.
///
/// La règle vit ici parce qu'elle vivait ailleurs en **trois exemplaires
/// divergents** : le modèle `Call` retenait 2 et 3, le badge d'appels manqués
/// de l'accueil en gardait une copie manuelle identique, et la bulle du fil de
/// discussion ne reconnaissait que 0. Chacune ratait une partie des appels.
///
/// Le statut 0 en fait partie, et c'est le point important. Deux conventions
/// ont cohabité : le schéma de `callHistory` déclare `0 = missed`, tandis que
/// le handler socket écrit 3 au timeout sans réponse et laisse 0 aux appels
/// annulés pendant la sonnerie. Reconnaître les deux, c'est classer
/// correctement les lignes à venir **et** celles déjà en base — 454 au
/// 31/08/2026, soit 22 % du journal — sans avoir à les réécrire.
///
/// Un appel réellement en cours n'est pas un contre-exemple : il est à
/// l'écran, pas dans le journal.
bool callWasNotAnswered(int status) => !callWasAnswered(status);

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
