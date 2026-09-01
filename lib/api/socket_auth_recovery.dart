/// Que faire quand le serveur refuse l'authentification du socket.
///
/// Le handler ne réagissait qu'à `TOKEN_EXPIRED` : pour tout autre échec il
/// posait `_isSocketAuthVerified = false` et rendait la main. Le socket TCP,
/// lui, restait parfaitement vivant — et c'est précisément l'état dont aucun
/// mécanisme de réparation ne sort. `ensureSocketReady()` ne recrée l'instance
/// que si elle est *déconnectée* ; le chien de garde ne s'arme que s'il y a des
/// messages en attente. Un appel en cours n'en produit aucun.
///
/// Or le `catch` global du serveur enveloppe une requête vers un MySQL distant.
/// Un pool saturé suffisait donc à tuer tout le temps réel — appels compris —
/// jusqu'au redémarrage de l'application.
library;

enum SocketAuthRecovery {
  /// Jeton d'accès périmé : le rafraîchir, puis réémettre `auth:login`.
  refreshToken,

  /// Échec passager : détruire l'instance et refaire une tentative plus tard.
  retryLater,

  /// Refus définitif — jeton invalide, compte banni, appareil révoqué.
  /// Réessayer ne ferait que marteler le serveur.
  giveUp,
}

/// Codes que le serveur émet pour un refus qui ne se répare pas tout seul.
const _refusDefinitifs = {
  'TOKEN_REQUIRED',
  'TOKEN_INVALID',
  'AUTH_REJECTED',
  'DEVICE_REVOKED',
};

/// Décide de la suite après un `auth:error`.
///
/// Un code **absent** vaut « passager » et non « définitif », délibérément :
/// c'est ce qu'émettait le serveur avant qu'on ne les nomme, et rester bloqué
/// pour toujours coûte plus cher qu'un nombre borné de tentatives inutiles.
SocketAuthRecovery socketAuthRecovery({
  String? code,
  required bool hasRefreshToken,
  required int attempts,
  int maxAttempts = 3,
}) {
  final c = code?.trim().toUpperCase() ?? '';
  if (c == 'TOKEN_EXPIRED') {
    return hasRefreshToken ? SocketAuthRecovery.refreshToken : SocketAuthRecovery.giveUp;
  }
  if (_refusDefinitifs.contains(c)) return SocketAuthRecovery.giveUp;
  if (attempts >= maxAttempts) return SocketAuthRecovery.giveUp;
  return SocketAuthRecovery.retryLater;
}

/// Attente avant la tentative numéro [attempts] (0 = la première).
///
/// Croissance géométrique bornée : un hoquet de base se répare en deux
/// secondes, une panne plus longue ne fait pas marteler le serveur.
Duration socketAuthRetryDelay(int attempts) {
  const base = 2;
  final secondes = base << (attempts.clamp(0, 3));
  return Duration(seconds: secondes.clamp(2, 16));
}
