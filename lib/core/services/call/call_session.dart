// Gestion session audio / foreground service pendant appels (part of call_service.dart).
part of '../call_service.dart';

extension CallSession on CallService {
  /// Identifiant présenté à CallKit, fabriqué si le serveur n'a pas encore
  /// donné le sien. Il est mémorisé à part : `_currentCallId` adoptera
  /// l'identifiant serveur au décrochage, alors que CallKit gardera celui-ci.
  String _ensureCallId() {
    if (_currentCallId == null || _currentCallId!.isEmpty) {
      _currentCallId = '${DateTime.now().millisecondsSinceEpoch}';
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
