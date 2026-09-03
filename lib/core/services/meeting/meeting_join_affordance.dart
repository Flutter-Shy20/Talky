/// Où en est une réunion, et peut-on encore la rejoindre.
///
/// Extrait de `_MeetingDetailScreenState`, qui décidait deux fois de la même
/// chose sans jamais rapprocher les deux : une `_computeStatus` privée pour la
/// puce d'état, et une condition écrite à la main pour le bouton flottant.
library;

/// Les cinq états d'une réunion, du point de vue de quelqu'un qui la regarde.
///
/// `terminee` et `echue` sont distinctes à dessein : la première est un geste —
/// l'organisateur a mis fin —, la seconde un simple constat d'horloge. Elles se
/// corrigent différemment côté serveur, et l'ancienne `_computeStatus` les
/// confondait sous « ended ».
enum MeetingPhase { programmee, bientot, enCours, echue, terminee }

/// Classe une réunion. [maintenant] est passé plutôt que lu, pour que la règle
/// se teste sans horloge.
MeetingPhase phaseReunion({
  required bool isEnd,
  required DateTime debut,
  required int dureeMinutes,
  required DateTime maintenant,
  Duration seuilBientot = const Duration(minutes: 15),
}) {
  if (isEnd) return MeetingPhase.terminee;

  final fin = debut.add(Duration(minutes: dureeMinutes));
  // Borne haute exclue : à la seconde exacte de la fin, la réunion est échue.
  if (!maintenant.isBefore(fin)) return MeetingPhase.echue;

  if (!maintenant.isBefore(debut)) return MeetingPhase.enCours;

  final avant = debut.difference(maintenant);
  if (avant <= seuilBientot) return MeetingPhase.bientot;
  return MeetingPhase.programmee;
}

/// Le bouton « Rejoindre » a-t-il encore un sens ?
///
/// Il survivait à la fin de la réunion : l'écran de détail rechargeait ses
/// données au mauvais moment — `.then` sur une route retirée par
/// `pushReplacement`, donc complété à l'entrée en réunion et jamais au retour —
/// et rien ne l'avertissait d'un `meeting:ended`. Il gardait donc l'état d'avant.
///
/// La règle reprend **exactement** le périmètre d'avant : tout sauf terminée et
/// échue. Rejoindre une réunion programmée pour la semaine prochaine reste
/// possible, comme aujourd'hui — restreindre cela serait une autre décision, qui
/// n'a rien à voir avec le défaut corrigé ici.
bool peutRejoindre(MeetingPhase phase) =>
    phase != MeetingPhase.terminee && phase != MeetingPhase.echue;

/// Cette réunion expose-t-elle des commandes caméra ?
///
/// `type_media` vaut 0 pour une réunion vidéo, 1 pour une réunion audio seule.
/// L'écran plein affichait la bascule caméra et le changement de caméra dans
/// les deux cas : en audio, `_initLocalStream` a déjà forcé `isVideoOff`, il
/// n'existe aucune piste vidéo, et `toggleVideo` sort sans rien faire. Deux
/// boutons qui ne répondent pas. Le lobby, lui, testait déjà `typeMedia`.
///
/// Une valeur inconnue — ou absente, le temps que la réunion soit chargée —
/// vaut « pas de caméra » : on n'offre jamais une commande dont on n'est pas
/// sûr qu'elle ait quelque chose à commander.
bool afficheCommandesCamera(int? typeMedia) => typeMedia == 0;
