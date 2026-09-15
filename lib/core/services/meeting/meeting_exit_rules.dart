/// Règles pures de fermeture de l'écran de réunion.
///
/// Extraites pour être testables sans `MeetingService`, sans WebRTC et sans
/// `Navigator` — même parti que `call_terminal_guards.dart`, dont ce fichier
/// reprend la convention : le statut arrive en **chaîne** (`MeetingStatus.name`)
/// plutôt qu'en énumération, pour ne rien importer du service.
library;

/// L'écran de réunion doit-il se fermer maintenant ?
///
/// Une seule sortie produisait **deux** `pop()`. Le premier venait de l'écoute
/// du service — statut passé à `ended` —, le second du bouton qui avait
/// déclenché cette sortie, qui popait de son côté après son `await`. Entre les
/// deux, la route est en `popping`, état que `_RouteEntry.isPresent` exclut : le
/// second `pop` retirait donc **la route du dessous**.
///
/// Quand l'écran avait été poussé sur le navigateur racine — réunion créée
/// depuis l'onglet Réunions, ou agrandie depuis le bandeau et la fenêtre
/// flottante —, la pile était `[AuthWrapper, OngoingMeetScreen]` : c'est la
/// route d'accueil qui sautait, le Navigator se vidait, et l'Overlay n'avait
/// plus rien à peindre. L'écran noir rapporté. Entré par l'écran de détail, pas
/// de noir — mais on remontait deux écrans au lieu d'un.
///
/// D'où cette règle et le `_closeOnce` qui la consomme : un seul propriétaire de
/// la fermeture, quel que soit celui qui arrive le premier. C'est la forme que
/// l'écran d'appel tient depuis toujours (`_closeAndPop` / `_hangUp`).
///
/// `idle` est terminal au même titre que `ended`. `MeetingService` s'arrête
/// aujourd'hui à `ended`, mais il enchaînera sur `idle` comme le fait déjà
/// `CallService` — sans quoi la bannière n'annonce jamais « Réunion terminée ».
/// Une règle qui ne connaîtrait que `ended` laisserait alors l'écran ouvert
/// selon l'ordonnancement des deux notifications. On l'accepte donc avant d'en
/// avoir besoin, plutôt que d'y revenir.
bool shouldPopMeetingScreen({
  required bool alreadyClosing,
  required String meetingStatusName,
}) {
  if (alreadyClosing) return false;
  return meetingStatusName == 'ended' || meetingStatusName == 'idle';
}
