import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'audio_helper.dart';
import 'call/background_media_rules.dart';
import 'call/call_audio_routes.dart';
import 'callkit_service.dart';

enum SessionMode { audio, video }

/// Ce que vaut une acquisition de la session média.
enum SessionAcquisition {
  /// Personne ne tenait la session : on la configure.
  fraiche,

  /// Le même appel la tient déjà — imbrication légitime, on compte.
  imbriquee,

  /// Un AUTRE appel la tient. On ne compte pas, et on le dit.
  conflit,
}

/// Faut-il rendre la session média à la demande de [releasedBy] ?
///
/// `acquire` refuse déjà proprement un conflit, sans compter — mais `release`
/// décrémentait aveuglément. Une session dont l'acquisition avait été REFUSÉE
/// faisait donc quand même tomber le compteur à zéro en se retirant, et
/// démontait celle du voisin : service au premier plan arrêté, focus audio
/// rendu, entrée CallKit fermée, verrou de veille et capteur de proximité
/// relâchés — sur un appel, ou une réunion, toujours en cours.
///
/// Le chemin est celui qu'`acquire` documente déjà : rejoindre une réunion
/// pendant un appel, ou décrocher un appel pendant une réunion. La correction
/// d'`acquire` était donc à moitié faite ; c'est l'autre moitié.
///
/// Un appelant qui ne sait pas s'identifier garde l'ancien comportement : on ne
/// peut pas lui refuser ce qu'on ne sait pas attribuer.
bool shouldReleaseSession({
  required int refCount,
  required String? heldBy,
  required String? releasedBy,
}) {
  if (refCount <= 0) return false;
  final rendeur = releasedBy?.trim() ?? '';
  final tenant = heldBy?.trim() ?? '';
  if (rendeur.isEmpty || tenant.isEmpty) return true;
  return rendeur == tenant;
}

/// Décide du sort d'un `acquire`, sans rien toucher.
///
/// Extraite parce que la version précédente incrémentait le compteur dans les
/// trois cas puis sortait sans rien configurer dans les deux derniers : le
/// `release()` d'en face ne redescendait alors jamais à zéro, et le verrou de
/// veille, le capteur de proximité, le service au premier plan, le focus audio
/// et l'entrée CallKit restaient tenus indéfiniment.
SessionAcquisition classerAcquisition({
  required int refCount,
  required String? tenuPar,
  required String callId,
}) {
  if (refCount <= 0) return SessionAcquisition.fraiche;
  if (tenuPar == callId) return SessionAcquisition.imbriquee;
  return SessionAcquisition.conflit;
}

/// Maintient micro + foreground service actifs pendant appels/réunions (Android).
/// Vidéo : wakelock écran + pause caméra en veille.
///
/// En pause/inactive : réactive la track audio existante — **jamais** getUserMedia.
/// Si la track est morte au resume : callback optionnel [onReplaceAudioNeeded].
class CallSessionGuard with WidgetsBindingObserver {
  CallSessionGuard._();
  static final CallSessionGuard instance = CallSessionGuard._();

  static const _callMediaChannel =
      MethodChannel('com.alanya237.alanya/call_media');
  static const _proximityChannel =
      MethodChannel('com.alanya237.alanya/proximity');

  int _refCount = 0;
  SessionMode? _mode;
  String? _callId;
  bool _wakelockEnabled = false;
  bool _proximityEnabled = false;

  /// Dernière sortie audio connue, tenue à jour même hors session.
  ///
  /// `_initAudioRoute` choisit la sortie AVANT que la session ne soit acquise :
  /// sans mémoire, la première route serait perdue et l'écran ne s'éteindrait
  /// qu'au premier changement manuel.
  CallAudioRoute _route = CallAudioRoute.earpiece;
  bool _videoPausedByLifecycle = false;
  bool _audioTrackEnded = false;
  bool _mediaFgsStarted = false;

  /// Le Picture-in-Picture système est ouvert (renseigné par le pont natif).
  ///
  /// Indispensable, et pas seulement informatif : en PiP Android, l'activité
  /// est en pause tout en restant visible, donc le seul cycle de vie ne suffit
  /// pas à décider du sort de la caméra.
  bool _systemPipActive = false;

  /// Dernier état connu du cycle de vie. Mémorisé parce que la décision sur la
  /// caméra se rejoue aussi à l'ouverture et à la fermeture du PiP, en dehors
  /// de tout changement de cycle de vie.
  bool _appBackgrounded = false;

  /// True quand la plateforme autorise la capture caméra en arrière-plan.
  ///
  /// Android l'accorde tant qu'un service de premier plan de type `camera`
  /// tourne — d'où la lecture de `_mediaFgsStarted` plutôt qu'un simple test
  /// de plateforme : sans le service, l'autorisation n'existe pas. iOS le
  /// refuse tant que `multitasking-camera-access` n'est pas accordée.
  bool get _cameraAllowedInBackground => _isAndroid && _mediaFgsStarted;

  MediaStream? Function()? _getLocalStream;
  bool Function()? _isVideoOn;
  bool Function()? _isMuted;
  Future<void> Function()? _onReplaceAudioNeeded;

  bool get isActive => _refCount > 0;

  /// Prend la session média, et **dit si elle est bien à cet appel-ci**.
  ///
  /// Le compteur de références sert à imbriquer plusieurs acquisitions du MÊME
  /// appel — `answerCall` après `acceptIncomingCallFromPush`, par exemple. Il
  /// incrémentait aussi pour un `callId` DIFFÉRENT, en sortant aussitôt sans
  /// rien configurer : `_callId` et le mode restaient ceux de la session
  /// précédente, et le `release()` d'en face ne pouvait plus redescendre à zéro.
  ///
  /// Le chemin est banal — rejoindre une réunion pendant un appel. La réunion
  /// n'obtenait aucune entrée CallKit, celle de l'appel était marquée
  /// « connectée », et à la fin de l'appel la notification restait affichée,
  /// chronomètre en marche, pour toute la durée de la réunion. Avec elle : le
  /// verrou de veille, le capteur de proximité, le service au premier plan et
  /// le focus audio, tous jamais rendus.
  ///
  /// Un conflit ne compte donc plus, et se voit.
  Future<bool> acquire({
    required SessionMode mode,
    required String callId,
    required String displayName,
    required String handle,
    required bool isVideo,
    bool startCallKit = true,
    MediaStream? Function()? getLocalStream,
    bool Function()? isVideoOn,
    bool Function()? isMuted,
    Future<void> Function()? onReplaceAudioNeeded,
  }) async {
    // Le web n'a ni service au premier plan ni CallKit : rien à tenir, et donc
    // aucun échec à signaler.
    if (kIsWeb) return true;

    switch (classerAcquisition(
      refCount: _refCount,
      tenuPar: _callId,
      callId: callId,
    )) {
      case SessionAcquisition.imbriquee:
        _refCount++;
        debugPrint(
          '[CallSessionGuard] Déjà actif pour cet appel (ref=$_refCount)',
        );
        return true;
      case SessionAcquisition.conflit:
        debugPrint(
          '[CallSessionGuard] ⛔ conflit : session tenue par $_callId, '
          'refus de $callId — le compteur ne bouge pas',
        );
        return false;
      case SessionAcquisition.fraiche:
        break;
    }

    _refCount++;

    _mode = mode;
    _callId = callId;
    _getLocalStream = getLocalStream;
    _isVideoOn = isVideoOn;
    _isMuted = isMuted;
    _onReplaceAudioNeeded = onReplaceAudioNeeded;
    _videoPausedByLifecycle = false;
    _audioTrackEnded = false;

    WidgetsBinding.instance.addObserver(this);

    await AudioHelper.configureCallAudio(isVideo: mode == SessionMode.video);

    await _startMediaForegroundService(isVideo: isVideo);

    if (startCallKit) {
      await CallKitService.instance.startOutgoingCall(
        callId: callId,
        displayName: displayName,
        handle: handle,
        isVideo: isVideo,
      );
    }

    await _applyScreenPolicy();

    _watchAudioTrack();

    debugPrint('[CallSessionGuard] Session acquise mode=$mode callId=$callId');
    return true;
  }

  Future<void> markConnected() async {
    if (kIsWeb || _callId == null) return;
    await CallKitService.instance.setConnected(_callId!);
  }

  /// La session média est-elle tenue par [callId] ?
  ///
  /// À interroger avant de démonter quoi que ce soit de partagé — la fenêtre
  /// flottante et les rendus vidéo appartiennent eux aussi à celui qui tient la
  /// session, et les libérer depuis une session refusée vide l'écran du voisin.
  bool holdsSession(String? callId) {
    if (kIsWeb) return false;
    return shouldReleaseSession(
      refCount: _refCount,
      heldBy: _callId,
      releasedBy: callId,
    );
  }

  /// Rend la session — **si elle est bien à cet appel-ci**. Voir
  /// [shouldReleaseSession].
  Future<void> release({String? callId}) async {
    if (kIsWeb) return;
    if (!shouldReleaseSession(
      refCount: _refCount,
      heldBy: _callId,
      releasedBy: callId,
    )) {
      if (_refCount > 0) {
        debugPrint(
          '[CallSessionGuard] ⛔ release ignoré : session tenue par $_callId, '
          'rendue par $callId',
        );
      }
      return;
    }
    _refCount--;
    if (_refCount > 0) return;

    WidgetsBinding.instance.removeObserver(this);

    // Avant tout le reste : un écran resté noir parce que le verrou de
    // proximité a survécu à l'appel ne se distingue pas d'un téléphone en panne.
    await _applyScreenPolicy();

    await _stopMediaForegroundService();

    await AudioHelper.releaseCallAudio();

    final tenu = _callId;
    if (tenu != null && tenu.isNotEmpty) {
      try {
        await CallKitService.instance.endCall(tenu);
        debugPrint('[CallSessionGuard] CallKit fermé callId=$tenu');
      } catch (e) {
        debugPrint('[CallSessionGuard] endCall error: $e');
      }
    }

    _mode = null;
    _callId = null;
    _getLocalStream = null;
    _isVideoOn = null;
    _isMuted = null;
    _onReplaceAudioNeeded = null;
    _videoPausedByLifecycle = false;
    _audioTrackEnded = false;
    _systemPipActive = false;
    _appBackgrounded = false;

    debugPrint('[CallSessionGuard] Session relâchée');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb || _refCount == 0) return;

    debugPrint('[CallSessionGuard] lifecycle=$state mode=$_mode');

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Uniquement réactiver la track existante — jamais getUserMedia ici.
      _ensureAudioTrackActive();
      _appBackgrounded = true;
      _applyLocalVideoPolicy();
    } else if (state == AppLifecycleState.resumed) {
      _appBackgrounded = false;
      AudioHelper.reactivateCallAudio();
      _ensureAudioTrackActive();
      _maybeReplaceAudioIfNeeded();
      _applyLocalVideoPolicy();
    }
  }

  /// Signale l'ouverture ou la fermeture du Picture-in-Picture système.
  ///
  /// Appelée par le pont natif. Elle rejoue la décision caméra : fermer le PiP
  /// alors que l'application reste en arrière-plan doit couper ce que son
  /// ouverture avait laissé passer.
  void setSystemPipActive(bool active) {
    if (_systemPipActive == active) return;
    _systemPipActive = active;
    debugPrint('[CallSessionGuard] PiP système=$active');
    if (_refCount == 0) return;
    _applyLocalVideoPolicy();
  }

  /// Coupe ou rétablit la caméra locale selon [localVideoShouldPause].
  ///
  /// La caméra ne se coupe plus par principe en arrière-plan : c'était le
  /// défaut à corriger. Elle continue d'émettre dès lors que la plateforme
  /// l'autorise, ou que le Picture-in-Picture est ouvert.
  void _applyLocalVideoPolicy() {
    final shouldPause = localVideoShouldPause(
      isVideo: _mode == SessionMode.video,
      appBackgrounded: _appBackgrounded,
      systemPipActive: _systemPipActive,
      cameraAllowedInBackground: _cameraAllowedInBackground,
    );

    if (shouldPause) {
      _pauseLocalVideo();
    } else if (_videoPausedByLifecycle) {
      _resumeLocalVideo();
    }
  }

  /// Réactive `enabled` sur la track audio locale. Ne capture pas de nouveau média.
  void _ensureAudioTrackActive() {
    if (_isMuted != null && _isMuted!()) return;
    final stream = _getLocalStream?.call();
    if (stream == null) return;
    final tracks = stream.getAudioTracks();
    if (tracks.isEmpty) {
      _audioTrackEnded = true;
      return;
    }
    final track = tracks.first;
    if (!track.enabled) {
      debugPrint('[CallSessionGuard] Réactivation track audio');
      track.enabled = true;
    }
  }

  void _watchAudioTrack() {
    final stream = _getLocalStream?.call();
    final tracks = stream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    final track = tracks.first;
    track.onEnded = () {
      _audioTrackEnded = true;
      debugPrint('[CallSessionGuard] Track audio ended');
    };
  }

  Future<void> _maybeReplaceAudioIfNeeded() async {
    if (_refCount == 0) return;
    final stream = _getLocalStream?.call();
    final tracks = stream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    final ended = _audioTrackEnded || tracks.isEmpty;
    if (!ended) return;

    final cb = _onReplaceAudioNeeded;
    if (cb == null) {
      debugPrint(
        '[CallSessionGuard] Track audio morte, pas de onReplaceAudioNeeded',
      );
      return;
    }

    debugPrint('[CallSessionGuard] Track audio morte → replaceTrack');
    try {
      await cb();
      _audioTrackEnded = false;
      _watchAudioTrack();
    } catch (e) {
      debugPrint('[CallSessionGuard] ** onReplaceAudioNeeded: $e');
    }
  }

  void _pauseLocalVideo() {
    final stream = _getLocalStream?.call();
    if (stream == null) return;
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return;
    final track = tracks.first;
    if (track.enabled) {
      track.enabled = false;
      _videoPausedByLifecycle = true;
      debugPrint('[CallSessionGuard] Vidéo locale suspendue (veille)');
    }
  }

  void _resumeLocalVideo() {
    if (_isVideoOn != null && !_isVideoOn!()) return;
    final stream = _getLocalStream?.call();
    if (stream == null) return;
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return;
    tracks.first.enabled = true;
    _videoPausedByLifecycle = false;
    debugPrint('[CallSessionGuard] Vidéo locale reprise');
  }

  /// Signale la sortie audio courante — et donc si le téléphone est à l'oreille.
  ///
  /// Appelée par `setAudioRoute`, l'entonnoir unique par lequel passent le choix
  /// d'ouverture, le bouton de la barre de contrôle et les branchements de
  /// casque détectés en cours d'appel. La politique d'écran suit ainsi la sortie
  /// sans que rien d'autre n'ait à y penser.
  Future<void> updateAudioRoute(CallAudioRoute route) async {
    if (kIsWeb) return;
    if (_route == route) return;
    _route = route;
    await _applyScreenPolicy();
  }

  /// Applique les deux règles d'écran à partir de l'état courant.
  ///
  /// Un seul endroit décide, et il est rejoué à chaque changement : acquisition,
  /// changement de sortie audio, libération. Les règles elles-mêmes sont pures
  /// et testées — voir `proximityBlankingApplies` et `screenWakelockApplies`.
  Future<void> _applyScreenPolicy() async {
    final callActive = _refCount > 0;

    final wantProximity = proximityBlankingApplies(
      route: _route,
      callActive: callActive,
    );
    if (wantProximity != _proximityEnabled) {
      await _setProximityBlanking(wantProximity);
    }

    final wantWakelock = screenWakelockApplies(
      isVideo: _mode == SessionMode.video,
      route: _route,
      callActive: callActive,
    );
    if (wantWakelock != _wakelockEnabled) {
      try {
        wantWakelock
            ? await WakelockPlus.enable()
            : await WakelockPlus.disable();
        _wakelockEnabled = wantWakelock;
        debugPrint('[CallSessionGuard] Wakelock=$wantWakelock');
      } catch (e) {
        debugPrint('[CallSessionGuard] ** Wakelock: $e');
      }
    }
  }

  Future<void> _setProximityBlanking(bool enabled) async {
    try {
      if (enabled) {
        // Le natif répond false quand l'appareil n'a pas de capteur : ne pas
        // retenir un état actif qu'aucun verrou ne soutient, sinon la remise à
        // zéro suivante serait sautée.
        final ok = await _proximityChannel.invokeMethod<bool>('enable');
        _proximityEnabled = ok ?? false;
      } else {
        await _proximityChannel.invokeMethod('disable');
        _proximityEnabled = false;
      }
      debugPrint('[CallSessionGuard] Proximité=$_proximityEnabled');
    } on MissingPluginException {
      // Web, tests, ou build sans le pont natif : l'appel continue sans.
      _proximityEnabled = false;
    } catch (e) {
      debugPrint('[CallSessionGuard] ** Proximité: $e');
      _proximityEnabled = false;
    }
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _startMediaForegroundService({required bool isVideo}) async {
    if (!_isAndroid) return;
    try {
      await _callMediaChannel.invokeMethod('start', {'isVideo': isVideo});
      _mediaFgsStarted = true;
      debugPrint(
        '[CallSessionGuard] CallMedia FGS start isVideo=$isVideo',
      );
    } catch (e) {
      debugPrint('[CallSessionGuard] ** CallMedia FGS start: $e');
    }
  }

  Future<void> _stopMediaForegroundService() async {
    if (!_isAndroid || !_mediaFgsStarted) return;
    try {
      await _callMediaChannel.invokeMethod('stop');
      debugPrint('[CallSessionGuard] CallMedia FGS stop');
    } catch (e) {
      debugPrint('[CallSessionGuard] ** CallMedia FGS stop: $e');
    } finally {
      _mediaFgsStarted = false;
    }
  }
}
