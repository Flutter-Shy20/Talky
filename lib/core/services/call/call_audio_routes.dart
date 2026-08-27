/// Sorties audio d'un appel : ce qui est disponible, ce qu'on choisit, et ce
/// vers quoi bascule le bouton. Logique pure, testable sans appareil.
///
/// Le bouton de la barre de contrôle ne connaissait que deux états, haut-parleur
/// allumé ou éteint. Avec un casque Bluetooth appairé, l'utilisateur n'avait
/// donc aucun moyen de savoir où sortait le son, ni de le rediriger.
library;

/// Ce que la plateforme rapporte, réduit à ce qui nous concerne.
///
/// `audio_session` distingue une dizaine de types d'appareils ; pour un appel,
/// seules comptent les quatre familles ci-dessous.
enum AudioOutputKind { earpiece, speaker, wired, bluetooth, other }

/// Sortie effectivement sélectionnable.
enum CallAudioRoute { earpiece, speaker, wired, bluetooth }

/// Traduit un `AudioDeviceType` (par son nom) en famille.
///
/// Passer par le nom plutôt que par le type garde ce fichier sans dépendance,
/// donc testable ; et le tableau de correspondance — l'endroit où l'on se
/// trompe — devient lui aussi vérifiable.
AudioOutputKind audioOutputKindFromTypeName(String typeName) {
  switch (typeName) {
    case 'builtInEarpiece':
      return AudioOutputKind.earpiece;
    case 'builtInSpeaker':
      return AudioOutputKind.speaker;
    case 'wiredHeadset':
    case 'wiredHeadphones':
    case 'headsetMic':
    case 'lineAnalog':
    case 'lineDigital':
    case 'usbHeadset':
      return AudioOutputKind.wired;
    case 'bluetoothSco':
    case 'bluetoothA2dp':
    case 'bluetoothLe':
      return AudioOutputKind.bluetooth;
    default:
      return AudioOutputKind.other;
  }
}

/// Routes proposables, dans l'ordre d'affichage.
///
/// L'écouteur et le haut-parleur existent toujours sur un téléphone, même
/// quand la plateforme ne les énumère pas — c'est le cas sur certains Android
/// dès qu'un périphérique externe est branché. Les deux sont donc toujours
/// offerts ; seuls le filaire et le Bluetooth dépendent de ce qui est présent.
List<CallAudioRoute> availableAudioRoutes(Set<AudioOutputKind> kinds) {
  return [
    CallAudioRoute.earpiece,
    CallAudioRoute.speaker,
    if (kinds.contains(AudioOutputKind.wired)) CallAudioRoute.wired,
    if (kinds.contains(AudioOutputKind.bluetooth)) CallAudioRoute.bluetooth,
  ];
}

/// Sortie retenue à l'ouverture de l'appel.
///
/// Un périphérique branché gagne : on ne renvoie pas le son dans le haut-parleur
/// du téléphone quand l'utilisateur porte un casque. À défaut, la vidéo passe au
/// haut-parleur et la voix à l'écouteur, comme avant.
CallAudioRoute defaultAudioRoute({
  required Set<AudioOutputKind> kinds,
  required bool isVideo,
}) {
  if (kinds.contains(AudioOutputKind.bluetooth)) return CallAudioRoute.bluetooth;
  if (kinds.contains(AudioOutputKind.wired)) return CallAudioRoute.wired;
  return isVideo ? CallAudioRoute.speaker : CallAudioRoute.earpiece;
}

/// Sortie suivante quand on appuie sur le bouton.
///
/// Simple rotation dans l'ordre d'affichage : avec deux routes le bouton reste
/// la bascule d'avant, avec trois ou quatre il fait le tour.
CallAudioRoute nextAudioRoute({
  required CallAudioRoute current,
  required List<CallAudioRoute> available,
}) {
  if (available.isEmpty) return current;
  final index = available.indexOf(current);
  if (index < 0) return available.first;
  return available[(index + 1) % available.length];
}

/// Sortie à retenir quand la liste change — un casque qu'on débranche, par
/// exemple. Conserve le choix de l'utilisateur tant qu'il reste possible.
CallAudioRoute resolveAudioRouteAfterChange({
  required CallAudioRoute current,
  required Set<AudioOutputKind> kinds,
  required bool isVideo,
}) {
  if (availableAudioRoutes(kinds).contains(current)) return current;
  return defaultAudioRoute(kinds: kinds, isVideo: isVideo);
}

/// True si le son sort par le haut-parleur du téléphone.
///
/// C'est le seul réglage que la couche WebRTC expose directement ; le Bluetooth
/// a son propre appel, et le filaire se sélectionne tout seul dès que le
/// haut-parleur est coupé.
bool speakerphoneForRoute(CallAudioRoute route) =>
    route == CallAudioRoute.speaker;
