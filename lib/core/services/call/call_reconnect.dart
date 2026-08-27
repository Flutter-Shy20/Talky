// Reconnexion mid-call 1-à-1 (grâce Disconnected, ICE restart caller-only).
part of '../call_service.dart';

extension CallReconnect on CallService {
  bool get isRestartInitiator {
    return isOneToOneRestartInitiator(isOutgoingCaller: _isOutgoingCaller);
  }

  void _wireOneToOneConnectionStateHandlers() {
    _webrtc.onConnectionFailure = null;
    _webrtc.onConnectionStateChanged = (state) {
      _onOneToOneConnectionState(state);
    };
  }

  void _onOneToOneConnectionState(RTCPeerConnectionState state) {
    if (_status != CallStatus.connected &&
        _status != CallStatus.reconnecting) {
      return;
    }
    if (_isEndingCall || _callEndedByUs) return;

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _onOneToOneMediaReconnected();
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      debugPrint('[CallService] PC closed (terminal) → endCall');
      unawaited(endCall());
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      debugPrint('[CallService] PC Disconnected → grâce reconnect');
      _enterReconnecting(reason: 'disconnected');
      _armDisconnectGraceThenRestart();
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      debugPrint('[CallService] PC Failed → ICE restart (caller) / wait (callee)');
      _enterReconnecting(reason: 'failed');
      if (isRestartInitiator) {
        unawaited(_attemptIceRestart());
      }
      // Callee : attend l'offer ; timeout global gère la fin.
    }
  }

  void _enterReconnecting({required String reason}) {
    if (_status == CallStatus.ended || _status == CallStatus.idle) return;
    if (_status != CallStatus.reconnecting) {
      _status = CallStatus.reconnecting;
      notify();
      debugPrint('[CallService] status=reconnecting ($reason)');
    }
    _armGlobalReconnectTimeout();
  }

  void _onOneToOneMediaReconnected() {
    _cancelDisconnectGrace();
    _cancelGlobalReconnectTimeout();
    _cancelIceRestartRetry();
    _iceRestartCount = 0;
    _isIceRestarting = false;
    if (_status == CallStatus.reconnecting) {
      _status = CallStatus.connected;
      notify();
      debugPrint('[CallService] status=connected (media recovered)');
    }
  }

  void _armDisconnectGraceThenRestart() {
    _cancelDisconnectGrace();
    _reconnectGraceTimer = Timer(CallService._reconnectGraceDuration, () {
      _reconnectGraceTimer = null;
      if (_status != CallStatus.reconnecting) return;
      if (_webrtc.isPcConnected) {
        _onOneToOneMediaReconnected();
        return;
      }
      if (isRestartInitiator) {
        unawaited(_attemptIceRestart());
      }
    });
  }

  void _cancelDisconnectGrace() {
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = null;
  }

  void _armGlobalReconnectTimeout() {
    if (_globalReconnectTimer != null) return;
    _globalReconnectTimer = Timer(CallService._globalReconnectTimeout, () {
      _globalReconnectTimer = null;
      if (_status != CallStatus.reconnecting) return;
      debugPrint('[CallService] ⏰ Timeout reconnect global → endCall');
      unawaited(endCall());
    });
  }

  void _cancelGlobalReconnectTimeout() {
    _globalReconnectTimer?.cancel();
    _globalReconnectTimer = null;
  }

  void _cancelAllReconnectTimers() {
    _cancelDisconnectGrace();
    _cancelGlobalReconnectTimeout();
    _cancelIceRestartRetry();
    _isIceRestarting = false;
  }

  /// Une offre de reprise est-elle partie trop récemment pour en refaire une ?
  ///
  /// Réémettre repart d'une génération neuve. Tant que la précédente n'a pas eu
  /// le temps d'être répondue, une seconde offre condamne la première : le pair
  /// répond à celle qu'il a traitée, et notre compteur a déjà avancé — la garde
  /// anti-périmé jette alors la seule réponse utile.
  bool get _restartOfferTooSoon => !canEmitRestartOffer(
        lastOfferAt: _lastRestartOfferAt,
        now: DateTime.now(),
        window: CallService._iceRestartOfferTimeout,
      );

  Future<void> _attemptIceRestart({bool force = false}) async {
    if (!isRestartInitiator) return;
    if (_isEndingCall || _callEndedByUs) return;
    if (_status != CallStatus.reconnecting && _status != CallStatus.connected) {
      return;
    }
    // `force` sert la reprise déclenchée par `call_resume` : l'offre encore
    // « en vol » est justement celle qui vient de se perdre avec le réseau.
    if (_isIceRestarting && !force) return;
    // Mais `force` ne dispense pas de l'espacement : un socket qui revient peut
    // livrer deux `call_resume` d'affilée, et deux offres coup sur coup tuent
    // la reprise au lieu de la sauver.
    if (_restartOfferTooSoon) {
      debugPrint('[CallService] ICE restart ignoré (offre récente en vol)');
      return;
    }
    if (_iceRestartCount >= CallService._maxIceRestarts) {
      debugPrint('[CallService] ICE restart max atteint → endCall');
      await endCall();
      return;
    }

    if (_webrtc.peerConnection == null) {
      // Pas de branche Recreating dans ce lot : ICE restart uniquement.
      // PC null / max retries → fin propre (end_call), pas de recreate PC.
      debugPrint('[CallService] ICE restart impossible (PC null) → endCall');
      await endCall();
      return;
    }

    _isIceRestarting = true;
    _iceRestartCount += 1;
    debugPrint('[CallService] ICE restart #$_iceRestartCount');

    if (!await _emitIceRestartOffer()) {
      // Rien n'a quitté le téléphone. Rendre la cartouche et lever le verrou :
      // sinon la reprise déclenchée par `call_resume` au retour du réseau se
      // heurtait à `_isIceRestarting`, et l'appel mourait au timeout global
      // sans qu'aucune offre n'ait jamais circulé.
      _isIceRestarting = false;
      _iceRestartCount -= 1;
    }
    _armIceRestartRetry();
  }

  /// Crée l'offre d'ICE restart et l'envoie. Rend `false` si rien n'est parti —
  /// le socket est le seul canal, et il peut être à terre au moment précis où
  /// on en a besoin.
  Future<bool> _emitIceRestartOffer() async {
    final peer = _remoteUserId;
    if (_webrtc.peerConnection == null || peer == null) return false;
    if (!_apiClient.isSocketReady) {
      debugPrint('[CallService] offre de reprise différée (socket non prêt)');
      return false;
    }

    final generation = _webrtc.bumpIceGeneration();
    try {
      final offer = await _webrtc.createOffer(iceRestart: true);
      final sent = _apiClient.sendSocketEvent(SocketEvents.callRejoin, {
        'targetUserId': peer.toString(),
        'offer': {'sdp': offer.sdp, 'type': offer.type},
        'generation': generation,
        if (_currentCallId != null) 'callId': _currentCallId,
      });
      debugPrint(
        '[CallService] offre de reprise generation=$generation '
        '${sent ? "émise" : "abandonnée (socket tombé entre-temps)"}',
      );
      if (sent) _lastRestartOfferAt = DateTime.now();
      return sent;
    } catch (e) {
      debugPrint('[CallService] ** ICE restart failed: $e');
      return false;
    }
  }

  /// Réémet l'offre de reprise tant que la reconnexion dure.
  ///
  /// Une offre disparaît sans que personne ne s'en aperçoive dans deux cas :
  /// le socket local est à terre au moment de l'émission, ou l'appareil du
  /// pair est absent — le serveur jette alors le `call_rejoin` en le
  /// journalisant, sans rien dire à l'émetteur. Une tentative unique laissait
  /// donc l'appel expirer au bout des 45 s, bloqué sur « Reconnexion… ».
  ///
  /// Mais réémettre est loin d'être gratuit : chaque offre repart d'une
  /// génération neuve, ce qui purge les candidats ICE en vol et invalide ceux
  /// que le pair envoie encore. Réémettre toutes les cinq secondes revenait à
  /// redémarrer la négociation avant qu'elle ait pu aboutir — le lien se
  /// rétablissait en apparence, sans qu'aucun média ne passe. On laisse donc
  /// à une offre déjà partie le temps de vivre, et on ne réémet que si elle
  /// est restée sans effet.
  ///
  /// Ces réémissions ne consomment pas le quota de `_maxIceRestarts`, qui
  /// borne les restarts sur un lien vivant : ici c'est le timeout global qui
  /// tranche.
  void _armIceRestartRetry() {
    if (_iceRestartRetryTimer != null) return;
    _iceRestartRetryTimer = Timer.periodic(
      CallService._iceRestartRetryInterval,
      (_) async {
        if (_status != CallStatus.reconnecting ||
            !isRestartInitiator ||
            _isEndingCall ||
            _callEndedByUs) {
          _cancelIceRestartRetry();
          return;
        }
        if (_webrtc.isPcConnected) {
          _onOneToOneMediaReconnected();
          return;
        }
        if (_restartOfferTooSoon) return; // une offre est en vol : la laisser négocier
        if (await _emitIceRestartOffer()) _isIceRestarting = true;
      },
    );
  }

  void _cancelIceRestartRetry() {
    _iceRestartRetryTimer?.cancel();
    _iceRestartRetryTimer = null;
    _lastRestartOfferAt = null;
  }

  /// Appelé quand le PC redevient connected après rejoin answer.
  void _markIceRestartComplete() {
    _isIceRestarting = false;
  }

  /// Réémet les candidats ICE de l'appel sortant au moment du décrochage.
  ///
  /// L'appelant rassemble les siens une à deux secondes après avoir créé son
  /// offre, donc pendant que le téléphone d'en face sonne — or à ce moment le
  /// destinataire n'a pas encore d'appareil actif, et le relais les jette.
  /// `onIceCandidate` ne repassant jamais par un candidat déjà émis, le
  /// destinataire décroche sans un seul candidat distant : aucune paire à
  /// tester, et une allocation TURN sans permission, donc sourde. L'appel reste
  /// muet jusqu'à ce qu'un ICE restart embarque les candidats dans le SDP —
  /// une vingtaine de secondes plus tard.
  ///
  /// Le serveur les met aussi en tampon désormais, mais ce rejeu ne coûte rien
  /// et vaut pour un backend qui n'aurait pas encore ce tampon. Les doublons
  /// sont sans effet : WebRTC ignore un candidat déjà connu.
  void _replayOutgoingIce() {
    if (_outgoingIceOutbox.isEmpty) return;
    final generation = _webrtc.iceGeneration;
    var sent = 0;
    for (final entry in _outgoingIceOutbox) {
      if (entry.generation != generation) continue;
      if (_apiClient.sendSocketEvent(SocketEvents.iceCandidate, entry.payload)) {
        sent += 1;
      }
    }
    debugPrint('[CallService] 🧊 $sent candidat(s) ICE rejoué(s) au décrochage');
    _outgoingIceOutbox.clear();
  }

  /// La renégociation a abouti — côté signalisation seulement.
  ///
  /// Un SDP échangé ne prouve pas que le média repasse : ICE a encore ses
  /// candidats à rassembler et ses chemins à tester, et il peut échouer.
  /// Déclarer l'appel rétabli ici faisait disparaître « Reconnexion… » et
  /// repartir le chrono sur un lien mort, sans plus rien pour le rattraper :
  /// le timeout global venait d'être annulé. On attend donc l'état de la
  /// PeerConnection, seul témoin du média — `_onOneToOneConnectionState` est
  /// déjà branché pour ça et appellera `_onOneToOneMediaReconnected` le moment
  /// venu. Si le lien n'était jamais tombé, il est déjà connecté : rien à
  /// attendre.
  void _onRejoinNegotiated() {
    _markIceRestartComplete();
    if (_webrtc.isPcConnected) {
      _onOneToOneMediaReconnected();
      return;
    }
    debugPrint(
      '[CallService] renégociation aboutie — média en attente '
      '(pc=${_webrtc.connectionState})',
    );
  }
}
