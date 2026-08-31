import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/session_video_renderers.dart';

void main() {
  group('alignement des rendus de groupe', () {
    test('un participant qui arrive obtient un rendu', () {
      final diff = diffGroupRenderers(
        existing: {'7701'},
        incoming: {'7701', '7702'},
      );

      expect(diff.toCreate, {'7702'});
      expect(diff.toDrop, isEmpty);
    });

    test('un participant qui part rend le sien', () {
      final diff = diffGroupRenderers(
        existing: {'7701', '7702'},
        incoming: {'7701'},
      );

      expect(diff.toCreate, isEmpty);
      expect(
        diff.toDrop,
        {'7702'},
        reason: 'un rendu oublié fuit la mémoire vidéo pour toute la session',
      );
    });

    test('un remplacement complet fait les deux', () {
      final diff = diffGroupRenderers(
        existing: {'7701'},
        incoming: {'7702'},
      );

      expect(diff.toCreate, {'7702'});
      expect(diff.toDrop, {'7701'});
    });

    test('sans changement, rien à faire', () {
      final diff = diffGroupRenderers(
        existing: {'7701', '7702'},
        incoming: {'7702', '7701'},
      );

      expect(
        diff.toCreate,
        isEmpty,
        reason: 'recréer un rendu existant noircirait la tuile d\'un '
            'participant qui parle encore',
      );
      expect(diff.toDrop, isEmpty);
    });

    test('le premier participant part de rien', () {
      final diff = diffGroupRenderers(existing: {}, incoming: {'7701'});

      expect(diff.toCreate, {'7701'});
      expect(diff.toDrop, isEmpty);
    });

    test('la fin de conférence rend tout', () {
      final diff = diffGroupRenderers(
        existing: {'7701', '7702'},
        incoming: {},
      );

      expect(diff.toCreate, isEmpty);
      expect(diff.toDrop, {'7701', '7702'});
    });
  });
}
