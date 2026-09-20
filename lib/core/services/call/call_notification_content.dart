/// Ce que porte la notification d'un appel en cours.
///
/// Elle est devenue la seule notification de l'appel : celle du plugin CallKit
/// est masquée depuis que les deux services au premier plan en posaient chacun
/// une. Deux décisions y sont assez subtiles pour mériter d'être tenues à part
/// et éprouvées.
library;

/// Titre à afficher, jamais vide.
///
/// [displayName] vaut le nom de l'interlocuteur pour un appel, l'objet pour une
/// réunion. Il peut manquer : un appel entrant d'un inconnu, ou une réunion
/// sans objet. Une notification intitulée par une chaîne vide se réduit à son
/// icône, et l'utilisateur ne sait plus ce qui tourne.
String callNotificationTitle({
  required String displayName,
  required String fallback,
}) {
  final nom = displayName.trim();
  return nom.isEmpty ? fallback : nom;
}

/// Le chronomètre doit-il tourner ?
///
/// Non tant que l'appel sonne. La notification est posée à l'acquisition de la
/// session — donc avant la réponse —, et un chronomètre parti de là annoncerait
/// une conversation qui n'a pas commencé : chez l'appelant, il aurait compté
/// toute la sonnerie. Il ne démarre qu'à `markConnected`, qui fournit alors
/// l'instant de référence.
///
/// [startedAt] est en millisecondes epoch ; zéro, ou négatif, signifie « pas
/// encore connecté ».
bool callNotificationUsesChronometer(int startedAt) => startedAt > 0;
