import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call/call_audio_routes.dart';

/// Routage audio WebRTC et session audio « appel » (voiceChat / videoChat).
class AudioHelper {
  static AudioSession? _session;
  static bool _callAudioActive = false;
  static bool _subscribed = false;

  /// Active la session audio pour un appel ou une réunion en cours.
  /// [isVideo] : mode iOS `videoChat` (sinon `voiceChat`).
  static Future<void> configureCallAudio({bool isVideo = false}) async {
    if (kIsWeb) return;
    try {
      _session ??= await AudioSession.instance;
      await _session!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: isVideo
            ? AVAudioSessionMode.videoChat
            : AVAudioSessionMode.voiceChat,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      await _session!.setActive(true);
      _callAudioActive = true;
      _ensureEventSubscriptions();
      debugPrint(
        '[AudioHelper] Session audio appel activée '
        '(${isVideo ? "videoChat" : "voiceChat"})',
      );
    } catch (e) {
      debugPrint('[AudioHelper] ** configureCallAudio: $e');
    }
  }

  /// Relâche la session audio à la fin d'un appel/réunion.
  static Future<void> releaseCallAudio() async {
    if (kIsWeb) return;
    _callAudioActive = false;
    try {
      await _session?.setActive(false);
      debugPrint('[AudioHelper] Session audio appel relâchée');
    } catch (e) {
      debugPrint('[AudioHelper] ** releaseCallAudio: $e');
    }
  }

  /// Réactive la session après retour au premier plan.
  static Future<void> reactivateCallAudio() async {
    if (kIsWeb || _session == null || !_callAudioActive) return;
    try {
      await _session!.setActive(true);
    } catch (e) {
      debugPrint('[AudioHelper] ** reactivateCallAudio: $e');
    }
  }

  static void _ensureEventSubscriptions() {
    if (_subscribed || _session == null) return;
    _subscribed = true;

    _session!.interruptionEventStream.listen((event) {
      if (!_callAudioActive) return;
      if (event.begin) {
        debugPrint(
          '[AudioHelper] Interruption début type=${event.type}',
        );
        return;
      }
      // Fin d'interruption pendant un appel : reprendre le focus audio.
      debugPrint('[AudioHelper] Interruption fin → setActive(true)');
      _session?.setActive(true).then((_) {}, onError: (Object e) {
        debugPrint('[AudioHelper] ** setActive après interruption: $e');
      });
    });

    _session!.becomingNoisyEventStream.listen((_) {
      if (!_callAudioActive) return;
      // Appel : on ne coupe pas l'audio (contrairement à un lecteur média).
      debugPrint('[AudioHelper] becomingNoisy pendant appel (ignoré)');
    });

    _session!.devicesChangedEventStream.listen((event) {
      if (!_callAudioActive) return;
      debugPrint(
        '[AudioHelper] devicesChanged '
        '+${event.devicesAdded.length} -${event.devicesRemoved.length}',
      );
      _outputsChanged.add(null);
    });
  }

  /// Émet à chaque branchement ou débranchement pendant un appel.
  static final StreamController<void> _outputsChanged =
      StreamController<void>.broadcast();

  /// Un casque appairé en cours d'appel doit se voir sans que l'utilisateur
  /// ait à toucher quoi que ce soit.
  static Stream<void> get audioOutputsChanged => _outputsChanged.stream;

  /// Familles de sorties audio actuellement disponibles.
  ///
  /// La liste plateforme est réduite aux quatre familles qui comptent pour un
  /// appel ; voir `call/call_audio_routes.dart` pour la correspondance.
  static Future<Set<AudioOutputKind>> availableOutputKinds() async {
    if (kIsWeb) return {};
    try {
      _session ??= await AudioSession.instance;
      final devices = await _session!.getDevices(includeInputs: false);
      final kinds = <AudioOutputKind>{};
      for (final device in devices) {
        final kind = audioOutputKindFromTypeName(device.type.name);
        if (kind != AudioOutputKind.other) kinds.add(kind);
      }
      return kinds;
    } catch (e) {
      debugPrint('[AudioHelper] ** availableOutputKinds: $e');
      return {};
    }
  }

  /// Applique une sortie.
  ///
  /// WebRTC n'expose directement que le haut-parleur ; le Bluetooth a son
  /// propre appel, et le filaire est choisi par le système dès que le
  /// haut-parleur est coupé.
  static Future<void> applyAudioRoute(CallAudioRoute route) async {
    if (kIsWeb) return;
    try {
      if (route == CallAudioRoute.bluetooth) {
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        await Helper.setSpeakerphoneOn(speakerphoneForRoute(route));
      }
      debugPrint('[AudioHelper] 🔊 Sortie audio: ${route.name}');
    } catch (e) {
      debugPrint('[AudioHelper] ** applyAudioRoute(${route.name}): $e');
    }
  }

  static Future<void> setSpeakerphoneOn(bool on) async {
    if (kIsWeb) return;
    try {
      await Helper.setSpeakerphoneOn(on);
      debugPrint('[AudioHelper] Speaker phone: $on');
    } catch (e) {
      debugPrint('[AudioHelper] ** setSpeakerphoneOn: $e');
    }
  }

  static Future<void> switchCamera(MediaStreamTrack videoTrack) async {
    if (kIsWeb) return;
    try {
      await Helper.switchCamera(videoTrack);
    } catch (e) {
      debugPrint('[AudioHelper] ** switchCamera: $e');
    }
  }
}
