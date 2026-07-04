// Contrôles médias (micro, caméra, haut-parleur) + timer de durée.
// part of call_service.dart.
part of '../call_service.dart';

extension CallControls on CallService {
  Future<void> toggleMute() async {
    // On dérive _isMuted du résultat RÉEL appliqué au track WebRTC
    // (et non d'un simple flip indépendant), pour ne jamais désynchroniser
    // l'icône affichée de l'état effectif du micro envoyé au correspondant.
    final micEnabled = await _webrtc.toggleMic();
    _isMuted = !micEnabled;
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
    notify();
  }

  Future<void> switchCamera() async {
    await _webrtc.switchCamera();
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