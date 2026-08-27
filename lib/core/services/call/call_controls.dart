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
  Future<void> setAudioRoute(CallAudioRoute route) async {
    _audioRoute = route;
    _isSpeakerOn = speakerphoneForRoute(route);
    await audio.AudioHelper.applyAudioRoute(route);
    debugPrint('[CallService] 🔊 Sortie audio: ${route.name}');
    notify();
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