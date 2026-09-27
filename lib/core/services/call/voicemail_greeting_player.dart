import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../media_cache_service.dart';

/// Lecteur de l'annonce vocale du répondeur, côté appelant.
///
/// **Pourquoi pas `VoicePlaybackService`.** Le lecteur central du dépôt refuse
/// les URL réseau (`throw StateError('Audio not downloaded')`), ne tient qu'un
/// seul flux global, écrase le contexte de chat, alimente le mini-lecteur et
/// applique la vitesse de lecture mémorisée par l'utilisateur. Jouer une
/// annonce avec lui arrêterait le vocal qu'on était en train d'écouter, et la
/// jouerait peut-être en accéléré.
///
/// **Le haut-parleur est gratuit, et c'est le point clé.** L'annonce se joue
/// APRÈS `_terminateCall()`, qui a déjà relâché la session audio d'appel. Un
/// lecteur qui ne touche pas à cette session sort alors par le canal
/// notification, c'est-à-dire le haut-parleur — exactement ce que fait déjà
/// `MessageSoundService.playCallEnd()`, avec le commentaire qui l'explique.
/// Aucune reconfiguration n'est nécessaire, et il ne FAUT surtout pas en faire :
/// la session est partagée avec les appels.
class VoicemailGreetingPlayer {
  VoicemailGreetingPlayer._();
  static final VoicemailGreetingPlayer instance = VoicemailGreetingPlayer._();

  static const _attributs = AndroidAudioAttributes(
    contentType: AndroidAudioContentType.speech,
    usage: AndroidAudioUsage.media,
  );

  /// Session de LECTURE, posée juste avant de jouer.
  ///
  /// Sans elle, l'annonce sortait dans l'écouteur, l'oreille collée au
  /// téléphone. La raison est que `_terminateCall()` désactive la session
  /// partagée (`setActive(false)`) mais ne la RECONFIGURE pas : elle reste en
  /// `playAndRecord` / `voiceChat`, c'est-à-dire en mode conversation, qui sur
  /// iOS route vers l'écouteur et sur Android vers le flux de communication.
  /// Ne rien faire ne suffisait donc pas.
  ///
  /// `playback` est la catégorie de lecture pure : elle sort au haut-parleur.
  /// La reconfigurer ici est sans danger pour les appels, parce que tout appel
  /// repose la sienne à son démarrage (`AudioHelper.configureCallAudio`).
  ///
  /// `duckOthers` plutôt que d'interrompre : si l'appelant écoutait de la
  /// musique, elle baisse le temps de l'annonce et reprend après.
  static const _sessionLecture = AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playback,
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
    avAudioSessionMode: AVAudioSessionMode.defaultMode,
    androidAudioAttributes: AndroidAudioAttributes(
      contentType: AndroidAudioContentType.speech,
      usage: AndroidAudioUsage.media,
    ),
    androidAudioFocusGainType:
        AndroidAudioFocusGainType.gainTransientMayDuck,
    androidWillPauseWhenDucked: false,
  );

  bool _sessionPosee = false;

  AudioPlayer? _player;
  final MediaCacheService _cache = MediaCacheService();

  /// Chemin local de l'annonce préparée, s'il y en a une.
  String? _pret;

  /// Téléchargement en vol, pour que la feuille puisse l'attendre sans le
  /// relancer.
  Future<String?>? _enVol;

  Stream<PlayerState>? get stateStream => _player?.playerStateStream;

  /// L'annonce est-elle en train de jouer ?
  ///
  /// `playing` seul ne suffit pas : `just_audio` le laisse à VRAI une fois la
  /// lecture terminée — il décrit l'intention, pas l'état du son. Le bouton
  /// restait donc bloqué sur « Couper l'annonce » indéfiniment, alors qu'il n'y
  /// avait plus rien à couper.
  bool get isPlaying {
    final p = _player;
    if (p == null) return false;
    return p.playing && p.processingState != ProcessingState.completed;
  }

  /// Lance le téléchargement SANS l'attendre.
  ///
  /// Appelé dès la réception de `call_voicemail`, donc avant le démontage de
  /// l'appel : le transfert se superpose à la libération de CallKit et à la
  /// fermeture de la connexion pair-à-pair, qui prennent de toute façon
  /// plusieurs centaines de millisecondes. Au deuxième appel vers la même
  /// personne, le cache répond sans réseau.
  ///
  /// Le nom du fichier change à chaque réenregistrement côté serveur : c'est ce
  /// qui fait office d'empreinte, puisque le cache indexe par nom et n'a aucune
  /// autre forme d'invalidation.
  void prefetch(String? url) {
    _pret = null;
    _enVol = null;
    if (url == null || url.isEmpty || kIsWeb) return;
    _enVol = _telecharger(url);
  }

  Future<String?> _telecharger(String url) async {
    try {
      final chemin = await _cache.ensureCached(url, maxBytes: 4 * 1024 * 1024);
      _pret = chemin;
      return chemin;
    } catch (e) {
      // Une annonce qui n'arrive pas n'est pas une panne : la feuille affiche
      // son texte et l'enregistrement reste possible. C'est la règle qui prime
      // sur tout le reste ici.
      debugPrint('[VoicemailGreeting] téléchargement échoué: $e');
      return null;
    }
  }

  /// Attend la fin du téléchargement lancé par [prefetch].
  Future<String?> whenReady() async {
    if (_pret != null) return _pret;
    return _enVol == null ? null : await _enVol;
  }

  /// Pose la session de lecture, une fois par cycle d'utilisation.
  ///
  /// Sans elle, l'annonce hérite de la configuration laissée par l'appel —
  /// mode conversation — et sort dans l'écouteur.
  Future<void> _poserLaSession() async {
    if (_sessionPosee || kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(_sessionLecture);
      await session.setActive(true);
      _sessionPosee = true;
    } catch (e) {
      // Une session qu'on ne peut pas poser ne doit pas empêcher d'entendre
      // quelque chose : on tente la lecture quand même.
      debugPrint('[VoicemailGreeting] session non posée: $e');
    }
  }

  /// Joue l'annonce depuis le début. Sans effet si rien n'a pu être téléchargé.
  Future<void> play() async {
    final chemin = await whenReady();
    if (chemin == null || !File(chemin).existsSync()) return;
    try {
      await _poserLaSession();
      _player ??= AudioPlayer(
        // `handleAudioSessionActivation: false` : c'est NOUS qui posons la
        // session ci-dessus, en connaissance de cause. La laisser à just_audio
        // reviendrait à la réactiver telle qu'elle était — en mode appel.
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );
      await _player!.setAndroidAudioAttributes(_attributs);
      await _player!.setFilePath(chemin);
      await _player!.seek(Duration.zero);
      await _player!.play();
    } catch (e) {
      debugPrint('[VoicemailGreeting] lecture échouée: $e');
    }
  }

  Future<void> pause() async {
    try {
      await _player?.pause();
    } catch (_) {}
  }

  /// Reprend, ou relance depuis le début si la lecture était terminée.
  Future<void> resume() async {
    final p = _player;
    if (p == null) return play();
    try {
      await _poserLaSession();
      if (p.processingState == ProcessingState.completed) {
        await p.seek(Duration.zero);
      }
      await p.play();
    } catch (e) {
      debugPrint('[VoicemailGreeting] reprise échouée: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  /// À la fermeture de la feuille : le son ne doit pas survivre à l'écran.
  ///
  /// Rend aussi le focus audio. Sans ça, la musique de l'utilisateur resterait
  /// baissée après l'annonce — c'est exactement le défaut que `ringtone_service`
  /// a dû corriger sur sa propre sonnerie.
  Future<void> release() async {
    _pret = null;
    _enVol = null;
    final p = _player;
    _player = null;
    try {
      await p?.stop();
      await p?.dispose();
    } catch (_) {}
    if (_sessionPosee) {
      _sessionPosee = false;
      try {
        final session = await AudioSession.instance;
        await session.setActive(false);
      } catch (_) {}
    }
  }
}
