import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;

/// Nature d'une panne, indépendante du domaine fonctionnel.
///
/// Sert à choisir *quoi dire* à l'utilisateur quand le serveur n'a pas envoyé
/// de code exploitable. Volontairement grossier : chaque valeur doit
/// correspondre à une phrase que l'on sait écrire et à une action que
/// l'utilisateur peut tenter.
enum ErrorKind {
  /// Pas de réseau du tout (DNS, interface coupée).
  horsLigne,

  /// Le réseau est là mais la réponse n'arrive pas.
  delaiDepasse,

  /// TLS refusé : certificat invalide, interception probable.
  reseauSuspect,

  /// 401/403 : session expirée ou droit manquant.
  nonAutorise,

  /// 404/410 : la ressource n'existe plus.
  introuvable,

  /// 409 : l'état côté serveur contredit la demande.
  conflit,

  /// 429 : trop de tentatives.
  tropDeRequetes,

  /// 5xx, ou réponse illisible.
  serveur,

  /// Micro, caméra, stockage ou localisation refusés par l'OS.
  permissionRefusee,

  /// Le périphérique existe mais est occupé ou absent.
  peripheriqueIndisponible,

  /// Écriture/lecture de fichier impossible.
  stockage,

  /// Rien de reconnaissable.
  inconnu,
}

/// Codes `PlatformException` qui signalent un refus de permission.
///
/// Le champ `code` est stable — contrairement au `message`, qui est traduit par
/// l'OS et reformulé d'une version à l'autre. C'est toute la raison de ne
/// jamais classer une erreur sur son texte.
const _codesPermission = {
  'permission',
  'PERMISSION_DENIED',
  'permission_denied',
  'CameraAccessDenied',
  'AudioAccessDenied',
  'photo_access_denied',
  'camera_access_denied',
  'NotAllowedError',
  'SecurityError',
};

/// Codes signalant un périphérique absent ou déjà pris par une autre app.
const _codesPeripherique = {
  'NotFoundError',
  'NotReadableError',
  'OverconstrainedError',
  'AbortError',
  'cameraNotFound',
  'audioNotFound',
};

/// Classe une panne HTTP à partir du seul code de statut.
///
/// `0` est la convention de [TalkyException] pour « la requête n'a jamais
/// abouti » : sans la cause d'origine on ne peut pas distinguer une coupure
/// réseau d'un délai dépassé, d'où le repli sur [ErrorKind.horsLigne], qui est
/// le cas de loin le plus fréquent et dont le conseil (« vérifiez votre
/// connexion ») reste juste dans les deux cas.
ErrorKind kindPourStatut(int statusCode) {
  if (statusCode == 0) return ErrorKind.horsLigne;
  if (statusCode == 401 || statusCode == 403) return ErrorKind.nonAutorise;
  if (statusCode == 404 || statusCode == 410) return ErrorKind.introuvable;
  if (statusCode == 409) return ErrorKind.conflit;
  if (statusCode == 429) return ErrorKind.tropDeRequetes;
  if (statusCode >= 500) return ErrorKind.serveur;
  if (statusCode >= 400) return ErrorKind.serveur;
  return ErrorKind.inconnu;
}

/// Classe une exception Dart brute par son **type**, jamais par son texte.
///
/// Remplace les `e.toString().toLowerCase().contains('permission')` qui
/// parsemaient le service d'appel : le message de `getUserMedia` n'est stable
/// ni entre versions de `flutter_webrtc`, ni entre Android et iOS, et il est
/// traduit par l'OS sur certaines plateformes.
///
/// L'ordre des tests compte : [HandshakeException] dérive de [IOException] et
/// doit être vu avant le cas réseau générique.
ErrorKind kindPourException(Object? erreur) {
  if (erreur == null) return ErrorKind.inconnu;

  if (erreur is TimeoutException) return ErrorKind.delaiDepasse;
  if (erreur is HandshakeException) return ErrorKind.reseauSuspect;
  if (erreur is SocketException) return ErrorKind.horsLigne;
  if (erreur is FileSystemException) return ErrorKind.stockage;

  if (erreur is PlatformException) {
    final code = erreur.code;
    if (_codesPermission.contains(code)) return ErrorKind.permissionRefusee;
    if (_codesPeripherique.contains(code)) {
      return ErrorKind.peripheriqueIndisponible;
    }
    // `code` reste plus fiable que `message`, même inconnu : on ne devine pas.
    return ErrorKind.inconnu;
  }

  // Dernier recours : les erreurs WebRTC arrivent en `Exception` anonymes dont
  // le nom de classe DOM est le seul indice typé disponible.
  final nom = erreur.runtimeType.toString();
  if (_codesPermission.contains(nom)) return ErrorKind.permissionRefusee;
  if (_codesPeripherique.contains(nom)) return ErrorKind.peripheriqueIndisponible;

  if (erreur is IOException) return ErrorKind.horsLigne;

  return ErrorKind.inconnu;
}
