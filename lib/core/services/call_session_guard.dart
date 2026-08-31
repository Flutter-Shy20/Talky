import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'audio_helper.dart';
import 'call/call_audio_routes.dart';
import 'callkit_service.dart';

enum SessionMode { audio, video }

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

  MediaStream? Function()? _getLocalStream;
  bool Function()? _isVideoOn;
  bool Function()? _isMuted;
  Future<void> Function()? _onReplaceAudioNeeded;

  bool get isActive => _refCount > 0;

  Future<void> acquire({
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
    if (kIsWeb) return;

    _refCount++;
    if (_refCount > 1) {
      debugPrint('[CallSessionGuard] Déjà actif (ref=$_refCount)');
      return;
    }

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
  }

  Future<void> markConnected() async {
    if (kIsWeb || _callId == null) return;
    await CallKitService.instance.setConnected(_callId!);
  }

  Future<void> release() async {
    if (kIsWeb) return;
    if (_refCount == 0) return;
    _refCount--;
    if (_refCount > 0) return;

    WidgetsBinding.instance.removeObserver(this);

    // Avant tout le reste : un écran resté noir parce que le verrou de
    // proximité a survécu à l'appel ne se distingue pas d'un téléphone en panne.
    await _applyScreenPolicy();

    await _stopMediaForegroundService();

    await AudioHelper.releaseCallAudio();

    final callId = _callId;
    if (callId != null && callId.isNotEmpty) {
      try {
        await CallKitService.instance.endCall(callId);
        debugPrint('[CallSessionGuard] CallKit fermé callId=$callId');
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
      if (_mode == SessionMode.video) {
        _pauseLocalVideo();
      }
    } else if (state == AppLifecycleState.resumed) {
      AudioHelper.reactivateCallAudio();
      _ensureAudioTrackActive();
      _maybeReplaceAudioIfNeeded();
      if (_mode == SessionMode.video && _videoPausedByLifecycle) {
        _resumeLocalVideo();
      }
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
