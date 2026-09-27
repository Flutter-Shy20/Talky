/// Règles pures du répondeur côté téléphone : ce que le bandeau montre, quand
/// il disparaît, et la forme exacte des écritures qu'on envoie au serveur.
/// Extraites pour être testables sans widget ni réseau.
///
/// Ce fichier ne calcule JAMAIS de créneau. Savoir si le répondeur intercepte
/// à cet instant demande de résoudre un fuseau par cascade — réglage de
/// l'appareil, puis pays du compte, puis serveur — et une seconde
/// implémentation de ce calcul finirait par diverger de la première. Le
/// serveur répond donc `active` et `activeUntil`, et tout ce qui suit s'appuie
/// dessus.
library;

import '../../../talky_models.dart';

/// Les échéances proposées à l'activation rapide.
///
/// Il n'y a délibérément AUCUNE option « sans fin ». Un répondeur qu'on oublie
/// d'éteindre est pire que pas de répondeur : son propriétaire croit son
/// téléphone joignable. La règle récurrente couvre le besoin durable, et elle
/// s'éteint d'elle-même chaque jour.
enum VoicemailQuickDuration {
  oneHour,
  fourHours,

  /// La prochaine occurrence de 8 h. Pas « demain 8 h » au sens littéral : à
  /// 2 h du matin, la prochaine est dans six heures, et proposer le lendemain
  /// matin enfermerait l'utilisateur pour trente heures sans qu'il l'ait
  /// demandé. La feuille affiche la date calculée, donc rien n'est ambigu.
  nextMorning,
}

/// L'heure de la bascule matinale, en heure murale locale.
const int voicemailMorningHour = 8;

/// Plafond de l'activation ponctuelle, imposé aussi par le serveur.
///
/// Ce n'est pas une limite technique mais le prolongement de la règle « aucune
/// activation sans échéance » : une durée qu'on peut pousser à une semaine
/// redevient un réglage qu'on oublie, et son propriétaire croit son téléphone
/// joignable. Qui veut une indisponibilité durable passe par les plages, qui
/// s'éteignent d'elles-mêmes chaque jour.
const Duration voicemailMaxDuration = Duration(hours: 24);

/// L'échéance demandée tient-elle dans le plafond ?
///
/// Vérifié ici pour refuser AVANT l'aller-retour réseau, avec un message clair.
/// Le serveur refuse de toute façon — ce n'est pas la seule garde.
bool isWithinMaxDuration(DateTime deadlineLocal, {required DateTime now}) =>
    !deadlineLocal.difference(now).isNegative &&
    deadlineLocal.difference(now) <= voicemailMaxDuration;

/// L'instant de fin d'une échéance rapide, en heure LOCALE.
///
/// Calculé sur l'appareil, en heure murale, puis converti en UTC au moment de
/// l'envoi. Le serveur ne re-dérive rien : `untilAt` est un instant absolu, ce
/// qui rend ce chemin — celui que presque tout le monde empruntera —
/// structurellement insensible au fuseau.
DateTime quickDeadline(VoicemailQuickDuration duration, {required DateTime now}) {
  switch (duration) {
    case VoicemailQuickDuration.oneHour:
      return now.add(const Duration(hours: 1));
    case VoicemailQuickDuration.fourHours:
      return now.add(const Duration(hours: 4));
    case VoicemailQuickDuration.nextMorning:
      final ceMatin = DateTime(now.year, now.month, now.day, voicemailMorningHour);
      if (ceMatin.isAfter(now)) return ceMatin;
      final demain = now.add(const Duration(days: 1));
      return DateTime(demain.year, demain.month, demain.day, voicemailMorningHour);
  }
}

/// Le corps du PATCH qui arme une activation ponctuelle.
Map<String, dynamic> activatePatch(DateTime deadlineLocal) => {
      'untilAt': deadlineLocal.toUtc().toIso8601String(),
    };

/// Le corps du PATCH du bouton « Désactiver ».
///
/// Les DEUX champs, et c'est le point. N'effacer que `untilAt` laisserait le
/// bandeau en place si un créneau récurrent est en cours : l'utilisateur
/// appuierait sur « Désactiver » et rien ne se passerait. Un geste, tout
/// s'éteint.
Map<String, dynamic> disablePatch() => {
      'untilAt': null,
      'enabled': false,
    };

/// Le bandeau doit-il s'afficher ?
///
/// [now] permet de devancer le serveur : il a répondu `active` au moment de la
/// lecture, mais l'échéance a pu passer depuis. Sans cette seconde condition,
/// le bandeau survivrait jusqu'au prochain aller-retour réseau.
bool shouldShowBanner(VoicemailSchedule? schedule, {required DateTime now}) {
  if (schedule == null || !schedule.active) return false;
  final fin = schedule.activeUntil;
  if (fin == null) return true; // journée entière : pas d'échéance à comparer
  return fin.isAfter(now);
}

/// Dans combien de temps ré-évaluer l'affichage du bandeau.
///
/// `null` = rien à programmer. Le minuteur vise l'échéance elle-même plutôt
/// qu'un battement régulier : un bandeau qui doit disparaître à 17 h n'a aucune
/// raison de réveiller le téléphone toutes les trente secondes jusque-là.
///
/// Une seconde de marge est ajoutée pour ne pas se réveiller juste avant la
/// bascule et devoir reprogrammer.
Duration? bannerRefreshDelay(VoicemailSchedule? schedule, {required DateTime now}) {
  if (schedule == null || !schedule.active) return null;
  final fin = schedule.activeUntil;
  if (fin == null) return null;
  final reste = fin.difference(now);
  if (reste.isNegative) return null;
  return reste + const Duration(seconds: 1);
}

/// `HH:MM` en heure locale, pour le bandeau. `null` si aucune échéance connue :
/// on écrit alors « Répondeur actif » sans heure, plutôt qu'une heure inventée.
String? deadlineLabel(DateTime? activeUntil) {
  if (activeUntil == null) return null;
  final local = activeUntil.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
