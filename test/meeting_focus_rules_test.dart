import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/meeting/meeting_focus_rules.dart';

void main() {
  group('focusEncoreValide', () {
    test('un participant distant toujours présent garde le focus', () {
      expect(
        focusEncoreValide(
          focusedId: '7',
          localId: '42',
          fluxDistants: {'7', '9'},
        ),
        '7',
      );
    });

    test('un participant distant qui vient de partir perd le focus', () {
      // Sans cette purge, l'overlay reste ouvert sur un flux mort — et comme le
      // retour arrière le ferme d'abord, l'écran devient inquittable.
      expect(
        focusEncoreValide(
          focusedId: '7',
          localId: '42',
          fluxDistants: {'9'},
        ),
        isNull,
      );
    });

    test('se mettre soi-même en avant survit à tout', () {
      // La tuile locale ne figure jamais dans `remoteStreams` : la comparer aux
      // clés distantes ferait disparaître le focus à la première notification.
      expect(
        focusEncoreValide(
          focusedId: '42',
          localId: '42',
          fluxDistants: const {},
        ),
        '42',
      );
    });

    test('aucun focus : rien à conserver', () {
      expect(
        focusEncoreValide(
          focusedId: null,
          localId: '42',
          fluxDistants: {'7'},
        ),
        isNull,
      );
    });

    test('identité locale inconnue : on ne garde que ce qui est présent', () {
      expect(
        focusEncoreValide(
          focusedId: '42',
          localId: null,
          fluxDistants: const {},
        ),
        isNull,
      );
      expect(
        focusEncoreValide(
          focusedId: '7',
          localId: null,
          fluxDistants: {'7'},
        ),
        '7',
      );
    });
  });

  group('actionRetour', () {
    test('focus ouvert : le retour le referme', () {
      expect(actionRetour(focusOuvert: true), MeetingBackAction.fermerFocus);
    });

    test('sans focus : le retour réduit la réunion, comme avant', () {
      expect(actionRetour(focusOuvert: false), MeetingBackAction.minimiser);
    });
  });
}
