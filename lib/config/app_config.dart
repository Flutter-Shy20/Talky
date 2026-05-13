/// ─── CONFIGURATION GLOBALE DE L'APPLICATION ─────────────────────────────────
///
/// COMMENT UTILISER :
///   Remplis token et serverUrl avant de lancer l'app.
///   currentUserId est rempli automatiquement par le socket au login.
///
class AppConfig {
  // ─── À REMPLIR AVANT DE TESTER ────────────────────────────────────────────

  /// Le JWT que tu récupères après le login.
  static String token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhbGFueWFJRCI6MTgsImVtYWlsIjoia2F6aXRpc3BAZ21haWwuY29tIiwidHlwZSI6ImFjY2VzcyIsImlhdCI6MTc3ODY2OTkxNSwiZXhwIjoxNzc4NjcwODE1fQ.nz4G8xzsW0HQNLW-kMaeVwYXAIM8kuBzmtaJnZrRHdI';
 
  /// L'adresse de ton serveur backend (sans slash final).
  /// Sur émulateur Android : "http://10.0.2.2:3000"
  /// Sur appareil physique  : "http://192.168.X.X:3000"
  static String serverUrl = 'http://10.2.3.62:3000';

  // ─── REMPLI AUTOMATIQUEMENT ───────────────────────────────────────────────

  /// L'alanyaID de l'utilisateur connecté.
  /// Rempli automatiquement dès que le socket reçoit 'auth:verified'.
  /// Utilisé pour déterminer quel côté (gauche/droite) afficher un message.
  static int currentUserId = 0;

  // ─────────────────────────────────────────────────────────────────────────

  static bool get isTokenSet => token.isNotEmpty;
  static bool get isLoggedIn => currentUserId != 0;

  static Map<String, String> get authHeaders => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };
}
