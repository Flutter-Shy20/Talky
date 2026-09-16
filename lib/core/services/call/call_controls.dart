// Contrôles médias (micro, caméra, haut-parleur) + timer de durée.
// part of call_service.dart.
part of '../call_service.dart';

extension CallControls on CallService {
  Future<void> toggleMute() async {
    await _webrtc.toggleMic();
    _isMuted = !_isMuted;
    speakingDetector.setSpeakerMuted(SpeakingDetector.localKey, _isMuted);
    // Notifier les autres participants de l'état micro
    final isGroup = _groupRoomId != null;
    if (isGroup) {
      _apiClient.sendSocketEvent(SocketEvents.groupMuteState, {
        'roomId': _groupRoomId,
        'isMuted': _isMuted,
      });
    } else if (_remoteUserId != null) {
      _apiClient.sendSocketEvent(SocketEvents.callMuteState, {
        'toUserId': _remoteUserId,
        'isMuted': _isMuted,
      });
    }
    notify();
  }

  Future<void> toggleCamera() async {
    await _webrtc.toggleCamera();
    _isVideoOn = !_isVideoOn;
    final isGroup = _groupRoomId != null;
    if (isGroup) {
      _apiClient.sendSocketEvent(SocketEvents.groupVideoState, {
        'roomId': _groupRoomId,
        'isVideoOn': _isVideoOn,
      });
    } else if (_remoteUserId != null) {
      _apiClient.sendSocketEvent(SocketEvents.callVideoState, {
        'toUserId': _remoteUserId,
        'isVideoOn': _isVideoOn,
      });
    }
    notify();
  }

  Future<void> switchCamera() async {
    await _webrtc.switchCamera();
  }

  /// Réémet mes états micro et caméra vers la salle.
  ///
  /// Rien ne transporte ces états à l'entrée d'un participant : `call_conf_peers`
  /// et `call_conf_joined` ne portent que l'identité, et les cartes de roster
  /// naissent « micro ouvert, caméra allumée ». Celui qui rejoignait voyait donc
  /// tout le monde non muet, et les autres le voyaient non muet lui aussi, quels
  /// que soient les états réels. Chacun réaffirme les siens à chaque arrivée.
  void _broadcastMyMediaState() {
    final roomId = _groupRoomId;
    if (roomId == null) return;
    _apiClient.sendSocketEvent(SocketEvents.groupMuteState, {
      'roomId': roomId,
      'isMuted': _isMuted,
    });
    _apiClient.sendSocketEvent(SocketEvents.groupVideoState, {
      'roomId': roomId,
      'isVideoOn': _isVideoOn,
    });
  }

  /// Passe à la sortie audio suivante.
  ///
  /// Avec les seules sorties intégrées, le bouton se comporte comme la bascule
  /// haut-parleur d'avant. Dès qu'un casque filaire ou Bluetooth est présent, il
  /// fait le tour des sorties disponibles.
  Future<void> toggleSpeaker() async {
    await setAudioRoute(
      nextAudioRoute(current: _audioRoute, available: _audioRoutes),
    );
  }

  /// Sélectionne une sortie précise.
  ///
  /// La sortie retenue est celle que le natif **rapporte**, pas celle demandée.
  /// Depuis que chaque appel est déclaré à Telecom, c'est lui qui arbitre le
  /// routage : afficher la demande revenait à annoncer un haut-parleur qui ne
  /// s'était pas allumé.
  Future<void> setAudioRoute(CallAudioRoute route) async {
    final rapportee = await audio.AudioHelper.applyAudioRoute(
      route,
      // Telecom ne connaît l'appel que sous l'identifiant qui a ouvert la
      // session CallKit, jamais sous celui du serveur.
      telecomCallId: _callKitCallId,
    );
    final effective = _adopterRouteRapportee(rapportee, route);
    // La sortie audio dit où est le téléphone : sur l'écouteur interne, il est
    // contre l'oreille et l'écran doit s'éteindre à l'approche. Ce point de
    // passage est unique — choix d'ouverture, bouton, casque branché en cours
    // d'appel y aboutissent tous —, donc c'est le seul endroit à prévenir.
    await CallSessionGuard.instance.updateAudioRoute(effective);
    debugPrint('[CallService] 🔊 Sortie audio: ${effective.name}');
    notify();
  }

  /// Adopte ce que le natif rapporte, et rend la sortie finalement retenue.
  ///
  /// Le masque de Telecom dit les sorties réellement atteignables : meilleure
  /// source que l'énumération des périphériques, qui n'annonce pas toujours
  /// l'écouteur interne. Quand il ne dit rien, on garde ce qu'on savait.
  CallAudioRoute _adopterRouteRapportee(
    audio.AppliedAudioRoute rapportee,
    CallAudioRoute demandee,
  ) {
    final masque = rapportee.supportedMask;
    if (masque != null) {
      final offertes = routesFromSupportedMask(masque);
      if (offertes.isNotEmpty) _audioRoutes = offertes;
    }
    final effective = resolveAppliedRoute(
      requested: demandee,
      reportedName: rapportee.routeName,
    );
    _audioRoute = effective;
    _isSpeakerOn = speakerphoneForRoute(effective);
    return effective;
  }

  /// Choisit la sortie d'ouverture d'un appel et se met à l'écoute des
  /// branchements.
  ///
  /// Remplace le `setSpeakerphoneOn(isVideo)` posé à l'initialisation : un
  /// casque déjà connecté doit être pris, plutôt que de renvoyer le son dans le
  /// haut-parleur du téléphone.
  Future<void> _initAudioRoute({required bool isVideo}) async {
    if (kIsWeb) return;
    final kinds = await audio.AudioHelper.availableOutputKinds();
    _audioRoutes = availableAudioRoutes(kinds);
    await setAudioRoute(defaultAudioRoute(kinds: kinds, isVideo: isVideo));
    _watchAudioOutputs(isVideo: isVideo);
  }

  /// Un casque branché ou débranché en cours d'appel doit se voir sans que
  /// l'utilisateur ait à toucher quoi que ce soit.
  void _watchAudioOutputs({required bool isVideo}) {
    _audioOutputsSub?.cancel();
    _audioOutputsSub = audio.AudioHelper.audioOutputsChanged.listen((_) async {
      final kinds = await audio.AudioHelper.availableOutputKinds();
      _audioRoutes = availableAudioRoutes(kinds);
      final resolved = resolveAudioRouteAfterChange(
        current: _audioRoute,
        kinds: kinds,
        isVideo: isVideo,
      );
      if (resolved != _audioRoute) {
        await setAudioRoute(resolved);
      } else {
        // Un casque qui se connecte peut faire rebasculer Telecom tout seul :
        // relire plutôt que supposer que rien n'a bougé.
        final lue = await audio.AudioHelper.readAppliedRoute(_callKitCallId);
        if (lue != null) _adopterRouteRapportee(lue, _audioRoute);
        notify();
      }
    });
  }

  void _stopWatchingAudioOutputs() {
    _audioOutputsSub?.cancel();
    _audioOutputsSub = null;
  }

  void _startDurationTimer() {
    _callDuration = 0;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _callDuration++;
      notify();
    });
  }
}