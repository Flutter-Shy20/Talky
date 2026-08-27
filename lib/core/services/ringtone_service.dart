import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:just_audio/just_audio.dart';
import 'package:vibration/vibration.dart';

import 'ringtone_preferences.dart';

/// Centralise les sons d'appel.

class RingtoneService {
  RingtoneService._();
  static final RingtoneService instance = RingtoneService._();

  static Future<void> stopAll() async {
    await instance.stop();
  }

  static const _ringbackAsset = 'assets/sounds/ringback.wav';

  final FlutterRingtonePlayer _systemRingtone = FlutterRingtonePlayer();
  AudioPlayer? _ringbackPlayer;
  AudioPlayer? _incomingCustomPlayer;
  AudioSession? _audioSession;

  _ActiveSound _active = _ActiveSound.none;
  /// Focus audio transitoire pris pour la sonnerie, à rendre à l'arrêt.
  bool _holdsAudioFocus = false;
  Timer? _vibrationTimer;

  Future<void> init() async {
    if (kIsWeb) return;
    _ringbackPlayer ??= AudioPlayer();
    _incomingCustomPlayer ??= AudioPlayer();
    _audioSession ??= await AudioSession.instance;
  } 

  Future<void> startIncomingRingtone({RingtoneOption? override}) async {
    if (kIsWeb) return;
    if (_active == _ActiveSound.incoming) return;
    if (_active != _ActiveSound.none) await stop();
    _active = _ActiveSound.incoming;

    final selection = override ?? RingtonePreferences.currentSelection;

    if (selection.type == RingtoneSourceType.system) {
      debugPrint('[RingtoneService] 🔔 Sonnerie système (appelé)');
      try {
        await _systemRingtone.playRingtone(looping: true, volume: 1.0, asAlarm: false);
        _startVibrationLoop();
      } catch (e) {
        debugPrint('[RingtoneService] ** Sonnerie système échouée: $e');
        _active = _ActiveSound.none;
      }
      return;
    }

    debugPrint('[RingtoneService] 🔔 Sonnerie personnalisée: ${selection.label}');
    try {
      await _configureCallAudioSession();
      final player = _incomingCustomPlayer!;
      if (selection.type == RingtoneSourceType.bundled) {
        await player.setAsset(selection.assetPath!);
      } else {
        await player.setFilePath(selection.filePath!);
      }
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(1.0);
      await player.play();
      _startVibrationLoop();
    } catch (e) {
      debugPrint('[RingtoneService] ** Sonnerie personnalisée échouée, repli système: $e');
      // Repli sur la sonnerie système si le fichier custom est illisible
      // (ex. supprimé manuellement du stockage entre deux sessions).
      try {
        await _systemRingtone.playRingtone(looping: true, volume: 1.0, asAlarm: false);
        _startVibrationLoop();
      } catch (e2) {
        debugPrint('[RingtoneService] ** Repli système également échoué: $e2');
        _active = _ActiveSound.none;
      }
    }
  }

  // Appelant : ringback custom 

  Future<void> startOutgoingRingback() async {
    if (kIsWeb) return;
    if (_active == _ActiveSound.outgoing) return;
    if (_active != _ActiveSound.none) await stop();
    _active = _ActiveSound.outgoing;
    debugPrint('[RingtoneService] 📞 Ringback (appelant)');

    try {
      await _configureCallAudioSession();
      final player = _ringbackPlayer!;
      await player.setAsset(_ringbackAsset);
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(0.7);
      await player.play();
    } catch (e) {
      debugPrint('[RingtoneService] ** Ringback échoué: $e');
      _active = _ActiveSound.none;
    }
  } 

  Future<void> stop() async {
    if (kIsWeb) return;
    final wasActive = _active;
    _active = _ActiveSound.none;

    _vibrationTimer?.cancel();
    _vibrationTimer = null;

    try {
      if (wasActive == _ActiveSound.incoming) {
        await _systemRingtone.stop();
        await _incomingCustomPlayer?.stop();
        try { await Vibration.cancel(); } catch (_) { /* vibration non supportée — ignoré */ }
      } else if (wasActive == _ActiveSound.outgoing) {
        await _ringbackPlayer?.stop();
      }
    } catch (e) {
      debugPrint('[RingtoneService] ** Stop: $e');
    }

    // Le focus audio pris par `_configureCallAudioSession` est transitoire
    // (`gainTransient`) mais n'était jamais rendu : après un appel manqué ou
    // refusé, la musique de l'utilisateur restait en pause indéfiniment.
    // `CallSessionGuard` a sa contrepartie depuis toujours — c'est
    // `AudioHelper.releaseCallAudio()`. Ne pas relâcher pendant un appel
    // décroché : la session d'appel a pris le relais entre-temps.
    if (wasActive != _ActiveSound.none) {
      await _releaseRingtoneAudioFocus();
    }
  }

  Future<void> _releaseRingtoneAudioFocus() async {
    final session = _audioSession;
    if (session == null || !_holdsAudioFocus) return;
    _holdsAudioFocus = false;
    try {
      await session.setActive(false);
      debugPrint('[RingtoneService] Focus audio de sonnerie relâché');
    } catch (e) {
      debugPrint('[RingtoneService] ** Relâche du focus: $e');
    }
  }

  Future<void> dispose() async {
    await stop();
    await _ringbackPlayer?.dispose();
    _ringbackPlayer = null;
    await _incomingCustomPlayer?.dispose();
    _incomingCustomPlayer = null;
  }

  Future<void> _configureCallAudioSession() async {
    final session = _audioSession;
    if (session == null) return;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.sonification,
        usage: AndroidAudioUsage.voiceCommunicationSignalling,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
      androidWillPauseWhenDucked: false,
    ));
    await session.setActive(true);
    _holdsAudioFocus = true;
  }

  void _startVibrationLoop() {
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try { Vibration.vibrate(duration: 700); } catch (_) { /* vibration non supportée — ignoré */ }
    _vibrationTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (_active != _ActiveSound.incoming) {
        _vibrationTimer?.cancel();
        return;
      }
      try { Vibration.vibrate(duration: 700); } catch (_) { /* vibration non supportée — ignoré */ }
    });
  }
}

enum _ActiveSound { none, incoming, outgoing }
