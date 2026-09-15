import 'package:talky_flutter/core/services/call/call_conf_routing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ouverture de l\'écran d\'appel (F1)', () {
    test('un join réussi ouvre l\'écran', () {
      expect(
        shouldOpenOngoingScreen(callStatusName: 'connected'),
        isTrue,
      );
      expect(
        shouldOpenOngoingScreen(callStatusName: 'joining'),
        isTrue,
      );
    });

    test('une erreur referme au lieu d\'ouvrir', () {
      expect(
        shouldOpenOngoingScreen(
          callStatusName: 'idle',
          errorMessage: 'Impossible de rejoindre',
        ),
        isFalse,
      );
    });

    test('un retour à idle sans message referme aussi', () {
      expect(
        shouldOpenOngoingScreen(callStatusName: 'idle'),
        isFalse,
        reason: 'joinGroupCall et acceptConferenceInvite avalent leurs erreurs '
            'et repassent en idle : l\'écran s\'ouvrait à 00:00, sans média, '
            'sans message et sans fermeture automatique',
      );
      expect(shouldOpenOngoingScreen(callStatusName: 'ended'), isFalse);
    });

    test('un message vide ne compte pas comme une erreur', () {
      expect(
        shouldOpenOngoingScreen(callStatusName: 'connected', errorMessage: ''),
        isTrue,
      );
    });
  });

  group('tuiles de la grille de conférence (F5)', () {
    test('un participant sans flux a quand même sa tuile', () {
      expect(
        conferenceTileIds(
          rosterIds: ['10', '20', '30'],
          streamIds: ['20'],
          myRosterId: '10',
        ),
        ['20', '30'],
        reason: 'pendant la négociation, il était invisible et le compte faux',
      );
    });

    test('l\'ordre des flux est conservé pour ceux qui en ont un', () {
      expect(
        conferenceTileIds(
          rosterIds: ['10', '20', '30', '40'],
          streamIds: ['40', '20'],
          myRosterId: '10',
        ),
        ['40', '20', '30'],
      );
    });

    test('on ne se compte pas soi-même', () {
      expect(
        conferenceTileIds(
          rosterIds: ['10', '20'],
          streamIds: ['10', '20'],
          myRosterId: '10',
        ),
        ['20'],
      );
    });

    test('un flux sans entrée de roster est ignoré', () {
      expect(
        conferenceTileIds(
          rosterIds: ['10', '20'],
          streamIds: ['20', '99'],
          myRosterId: '10',
        ),
        ['20'],
        reason: 'un flux résiduel d\'un participant parti ne doit pas '
            'ressusciter une tuile',
      );
    });

    test('roster vide : aucune tuile', () {
      expect(
        conferenceTileIds(rosterIds: [], streamIds: ['20'], myRosterId: '10'),
        isEmpty,
      );
    });

    test('sans identité locale connue, personne n\'est retiré', () {
      expect(
        conferenceTileIds(rosterIds: ['10', '20'], streamIds: []),
        ['10', '20'],
      );
    });
  });
}
