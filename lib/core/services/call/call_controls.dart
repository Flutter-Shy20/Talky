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

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await audio.AudioHelper.setSpeakerphoneOn(_isSpeakerOn);
    debugPrint('[CallService] Haut-parleur: ${_isSpeakerOn ? "ON" : "OFF"}');
    notify();
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