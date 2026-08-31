/// Ce qu'il advient de la caméra quand l'application passe en arrière-plan
/// pendant un appel. Logique pure, testable sans appareil.
library;

/// True si la piste vidéo locale doit être coupée.
///
/// La règle était « en arrière-plan, on coupe », et c'est ce qui interrompait
/// l'image du correspondant dès qu'on quittait Alanya. Trois conditions la
/// rendent aujourd'hui plus juste.
///
/// [systemPipActive] d'abord, et c'est le piège principal : en Picture-in-Picture
/// Android, l'activité est **en pause tout en restant visible**. Se fier au seul
/// cycle de vie couperait donc la caméra au moment précis où le PiP s'ouvre —
/// exactement l'inverse du but recherché.
///
/// [cameraAllowedInBackground] ensuite, qui n'est pas une préférence mais un
/// fait de plateforme. Android l'autorise tant qu'un service de premier plan de
/// type `camera` tourne — c'est le cas de `CallMediaForegroundService`. iOS le
/// refuse sans l'autorisation `multitasking-camera-access`, et suspendra la
/// capture de lui-même : autant relâcher la piste proprement plutôt que de la
/// laisser dans un état que le système a déjà tranché.
bool localVideoShouldPause({
  required bool isVideo,
  required bool appBackgrounded,
  required bool systemPipActive,
  required bool cameraAllowedInBackground,
}) {
  if (!isVideo) return false;
  if (!appBackgrounded) return false;
  if (systemPipActive) return false;
  return !cameraAllowedInBackground;
}
