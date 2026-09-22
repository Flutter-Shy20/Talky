// Navigation et état UI minimisée pour les appels (part of call_service.dart).
part of '../call_service.dart';

extension CallUi on CallService {
  /// Voir `isActiveCallStatus` — la décision est extraite pour être testée.
  bool get isCallActive => isActiveCallStatus(_status.name);

  bool get isCallUiMinimized => _isCallUiMinimized;

  bool get isCallUiRouteOpen => _isCallUiRouteOpen;

  bool get shouldShowCallBanner => isCallActive && _isCallUiMinimized;

  /// L'écran plein est affiché (push effectué).
  void markCallUiVisible() {
    _isCallUiRouteOpen = true;
    _isCallUiMinimized = false;
    notify();
  }

  /// L'utilisateur a quitté l'écran sans raccrocher → bannière.
  void markCallUiMinimized() {
    _isCallUiRouteOpen = false;
    _isCallUiMinimized = true;
    notify();
  }

  /// Route fermée (pop terminé).
  void markCallUiClosed() {
    _isCallUiRouteOpen = false;
    notify();
  }

  void _resetCallUiState() {
    _isCallUiMinimized = false;
    _isCallUiRouteOpen = false;
  }

  Future<void> showCallScreen() async {
    if (!isCallActive || _isCallUiRouteOpen) return;

    final navigator = appNavigator;
    if (navigator == null) return;

    // Réservation **synchrone**, avant le push.
    //
    // `markCallUiVisible` ne pose le drapeau qu'au post-frame de l'écran — et
    // il le faut : il appelle `notify()`, ce qui pendant la phase de
    // construction ferait lever tous les `Consumer`. Mais la garde ci-dessus le
    // teste avant de pousser : entre le `push` et ce post-frame, un second
    // appel la franchissait et poussait un **deuxième écran**. Le chronomètre
    // de la bannière traverse cette fenêtre chaque seconde.
    //
    // La réservation ne notifie pas — elle peut tomber pendant un build — et
    // reste idempotente avec le `markCallUiVisible` qui la confirmera.
    _isCallUiRouteOpen = true;
    try {
      await navigator.push(
        MaterialPageRoute(builder: (_) => const OngoingCallScreen()),
      );
    } catch (e) {
      // Libération garantie : un push refusé verrouillerait sinon le drapeau,
      // et plus aucun écran d'appel ne s'ouvrirait.
      _isCallUiRouteOpen = false;
      debugPrint('[CallService] ouverture de l\'écran d\'appel échouée: $e');
      rethrow;
    }

    markCallUiClosed();
    if (isCallActive && !_isCallUiMinimized) {
      markCallUiMinimized();
    }
  }

  /// Ouvre la feuille « laisser un message », après un `call_voicemail`.
  ///
  /// À n'appeler qu'une fois `_terminateCall()` **terminé**. L'appel sortant a
  /// acquis le micro et basculé la session audio en catégorie `call` avant même
  /// d'émettre `call_user` ; démarrer l'enregistreur avant que
  /// `_releaseCallSession` n'ait rendu cette session donne un fichier en bande
  /// téléphonique sur Android, et un échec sec sur iOS.
  ///
  /// Le contexte du navigateur racine suffit : `MultiProvider` est monté
  /// au-dessus de `MaterialApp`, donc `ChatProvider` y est visible.
  Future<void> showVoicemailSheet({
    required int peerUserId,
    required String peerName,
    int? conversationID,
    bool didRing = false,
  }) async {
    final navigator = appNavigator;
    if (navigator == null) return;
    await showVoicemailRecorder(
      context: navigator.context,
      peerName: peerName,
      peerUserId: peerUserId,
      conversationID: conversationID,
      didRing: didRing,
    );
  }

  /// Ouvre l'écran plein (depuis n'importe quel contexte, y compris la bannière).
  Future<void> navigateToCallUi([BuildContext? context]) async {
    if (context != null && !context.mounted) return;
    if (!isCallActive || _isCallUiRouteOpen) return;
    await showCallScreen();
  }
}
