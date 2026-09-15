// Gestion session audio / foreground service pendant appels (part of call_service.dart).
part of '../call_service.dart';

extension CallSession on CallService {
  /// Identifiant présenté à CallKit, fabriqué si le serveur n'a pas encore
  /// donné le sien. Il est mémorisé à part : `_currentCallId` adoptera
  /// l'identifiant serveur au décrochage, alors que CallKit gardera celui-ci.
  String _ensureCallId() {
    if (_currentCallId == null || _currentCallId!.isEmpty) {
      _currentCallId = '${DateTime.now().millisecondsSinceEpoch}';
      // Fabriqué, donc inconnu du serveur : tant qu'il n'aura pas annoncé le
      // sien, les gardes de callId n'ont rien à comparer.
      _serverCallIdKnown = false;
    }
    _callKitCallId = _currentCallId;
    return _currentCallId!;
  }

  Future<void> _acquireCallSession({
    required bool isVideo,
    required String displayName,
    required String handle,
    bool startCallKit = true,
  }) async {
    if (kIsWeb) return;
    // Retenu avant `_ensureCallId`, qui va le réécrire : sur un refus, c'est le
    // seul moyen de retrouver sous quel identifiant la session est tenue.
    final tenuAvant = _callKitCallId;
    final callId = _ensureCallId();
    final pris = await CallSessionGuard.instance.acquire(
      mode: isVideo ? SessionMode.video : SessionMode.audio,
      callId: callId,
      displayName: displayName,
      handle: handle,
      isVideo: isVideo,
      startCallKit: startCallKit,
      getLocalStream: () => _webrtc.localStream,
      isVideoOn: () => _isVideoOn,
      isMuted: () => _isMuted,
      onReplaceAudioNeeded: () async {
        await _webrtc.replaceAudioTrack(
          keepMuted: _isMuted,
          type: _isVideo ? CallType.video : CallType.audio,
        );
      },
    );
    if (!pris) {
      // Une autre session tient déjà le garde. On ne lie pas les rendus et on
      // ne réclame pas le mode image dans l'image : ils appartiennent à l'autre.
      //
      // Mais `_ensureCallId` a déjà réécrit `_callKitCallId`, et le laisser sur
      // un identifiant que le garde ne connaît pas orphelinerait la session.
      // C'est le cas d'un appel à deux converti en appel à trois : le garde tient
      // l'appel d'origine, `acceptConferenceInvite` réclame la session sous
      // l'identifiant de la conférence et se la voit refuser. `_releaseCallSession`
      // demandait ensuite de rendre cet identifiant-là, ne le reconnaissait pas et
      // repartait sans rien rendre — service au premier plan, wakelock, entrée
      // CallKit et éligibilité au Picture-in-Picture survivaient à l'appel, si
      // bien que quitter l'application ouvrait ensuite une vignette vide.
      _callKitCallId = tenuAvant;
      debugPrint('[CallService] ⛔ session média refusée pour $callId');
      return;
    }

    await _bindSessionRenderers();
    // L'éligibilité au PiP se déclare à l'ouverture, pas au moment de sortir :
    // Android n'accepte l'entrée que depuis `onUserLeaveHint`, quand il est
    // trop tard pour poser la question.
    await SystemPip.instance.setEligible(isVideo);
  }

  /// Ouvre les rendus vidéo pour la durée de la session.
  ///
  /// Ils appartenaient à l'écran plein, qui les créait à l'ouverture et les
  /// libérait à la fermeture. La fenêtre flottante doit continuer à montrer
  /// l'appel une fois l'écran quitté : la propriété remonte donc ici, aux
  /// bornes de la session.
  Future<void> _bindSessionRenderers() async {
    if (!isVideo) return;
    final renderers = SessionVideoRenderers.instance;
    await renderers.ensureInitialized();
    renderers.bind(this, () {
      renderers.syncMain(
        localStream: localStream,
        remoteStream: activeRemoteStream,
      );
      unawaited(renderers.syncGroup(groupRemoteStreams));
    });
  }

  Future<void> _markCallSessionConnected() async {
    if (kIsWeb) return;
    await CallSessionGuard.instance.markConnected();
  }

  Future<void> _releaseCallSession() async {
    if (kIsWeb) return;
    // La fenêtre flottante et les rendus vidéo appartiennent à celui qui tient
    // la session : les libérer depuis un appel dont l'acquisition avait été
    // REFUSÉE viderait l'écran de la réunion toujours en cours. On demande donc
    // d'abord si la session est bien la nôtre.
    final aNous = CallSessionGuard.instance.holdsSession(_callKitCallId);
    if (!aNous) {
      debugPrint(
        '[CallService] session média non tenue par $_callKitCallId — '
        'rien à rendre',
      );
      return;
    }
    // Avant le garde : la fenêtre flottante disparaît avec la session, et rien
    // ne doit rester branché sur des rendus en cours de libération.
    await SystemPip.instance.reset();
    await SessionVideoRenderers.instance.release();
    await CallSessionGuard.instance.release(callId: _callKitCallId);
  }
}
