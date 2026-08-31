import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/session_overlay_rules.dart';

void main() {
  SessionOverlays overlays({
    bool callActive = false,
    bool callMinimized = false,
    bool callIsVideo = false,
    bool meetingActive = false,
    bool meetingMinimized = false,
    bool meetingIsVideo = false,
    bool voicePlaying = false,
  }) =>
      sessionOverlays(
        callActive: callActive,
        callMinimized: callMinimized,
        callIsVideo: callIsVideo,
        meetingActive: meetingActive,
        meetingMinimized: meetingMinimized,
        meetingIsVideo: meetingIsVideo,
        voicePlaying: voicePlaying,
      );

  group('appel minimisé', () {
    test('un appel vidéo passe à la fenêtre, pas au bandeau', () {
      final o = overlays(
        callActive: true,
        callMinimized: true,
        callIsVideo: true,
      );

      expect(o.videoWindow, isTrue);
      expect(
        o.banner,
        isFalse,
        reason: 'la fenêtre remplace le bandeau — les deux feraient doublon',
      );
    });

    test('un appel audio garde le bandeau', () {
      final o = overlays(callActive: true, callMinimized: true);

      expect(o.banner, isTrue);
      expect(o.videoWindow, isFalse);
    });

    test('écran plein ouvert : aucune des deux surfaces', () {
      final o = overlays(callActive: true, callIsVideo: true);

      expect(o.videoWindow, isFalse);
      expect(o.banner, isFalse);
    });
  });

  group('réunion', () {
    test('une réunion vidéo minimisée a droit à la fenêtre', () {
      final o = overlays(
        meetingActive: true,
        meetingMinimized: true,
        meetingIsVideo: true,
      );

      expect(o.videoWindow, isTrue);
    });

    test('un appel en cours prend le pas sur la réunion', () {
      final o = overlays(
        callActive: true,
        callMinimized: true,
        callIsVideo: true,
        meetingActive: true,
        meetingMinimized: true,
        meetingIsVideo: false,
      );

      expect(o.videoWindow, isTrue);
      expect(
        o.banner,
        isFalse,
        reason: 'la réunion ne doit pas s\'afficher derrière l\'appel',
      );
    });
  });

  group('lecture vocale', () {
    test('seule, elle occupe le bandeau', () {
      final o = overlays(voicePlaying: true);

      expect(o.banner, isTrue);
      expect(o.videoWindow, isFalse);
    });

    test('elle cohabite avec la fenêtre vidéo', () {
      final o = overlays(
        callActive: true,
        callMinimized: true,
        callIsVideo: true,
        voicePlaying: true,
      );

      expect(o.videoWindow, isTrue);
      expect(
        o.banner,
        isTrue,
        reason: 'la vidéo ayant quitté le bandeau, le vocal y a enfin la '
            'place — il disparaissait derrière l\'appel jusqu\'ici',
      );
    });
  });

  test('rien en cours : aucune surface', () {
    final o = overlays();

    expect(o.banner, isFalse);
    expect(o.videoWindow, isFalse);
  });
}
