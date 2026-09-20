// `answerCall` enchaîne quatre attentes — capture, socket, PeerConnection,
// accusé — sans revérifier que l'appel existe encore. Quand un aperçu CallKit
// le faisait refuser en plein milieu, elle continuait sur un état remis à zéro :
// réponse envoyée à un appel que le serveur ne connaissait plus, statut
// « connecté », et session CallKit rouverte sous un identifiant fabriqué —
// l'écran « Appel » au chronomètre, avec personne en face.

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  group('le décrochage en cours porte-t-il encore sur son appel', () {
    test('cas nominal : même appel, toujours en connexion', () {
      expect(
        answerStillValid(
          callStatusName: 'connecting',
          callIdAtStart: '2332',
          currentCallId: '2332',
        ),
        isTrue,
      );
    });

    test('l\'appel courant a changé : on abandonne', () {
      expect(
        answerStillValid(
          callStatusName: 'connecting',
          callIdAtStart: '2332',
          currentCallId: '2339',
        ),
        isFalse,
        reason: 'un autre appel a pris la place pendant une attente : envoyer '
            'la réponse engagerait le serveur sur le mauvais',
      );
    });

    test('l\'appel a été démonté : identifiant effacé', () {
      expect(
        answerStillValid(
          callStatusName: 'connecting',
          callIdAtStart: '2332',
          currentCallId: null,
        ),
        isFalse,
        reason: '_resetCallState efface l\'identifiant : c\'est la trace du '
            'démontage qui produisait l\'appel fantôme',
      );
    });

    test('le statut n\'est plus celui d\'un décrochage', () {
      for (final statut in ['idle', 'ended', 'incoming', 'connected']) {
        expect(
          answerStillValid(
            callStatusName: statut,
            callIdAtStart: '2332',
            currentCallId: '2332',
          ),
          isFalse,
          reason: statut,
        );
      }
    });

    test('une fin d\'appel engagée arrête tout', () {
      expect(
        answerStillValid(
          callStatusName: 'connecting',
          callIdAtStart: '2332',
          currentCallId: '2332',
          endingCall: true,
        ),
        isFalse,
        reason: 'raccrochage local en cours : la réponse n\'a plus de sens',
      );
    });

    test('un appel sans identifiant serveur reste valide s\'il n\'a pas bougé',
        () {
      expect(
        answerStillValid(
          callStatusName: 'connecting',
          callIdAtStart: null,
          currentCallId: null,
        ),
        isTrue,
        reason: 'certains chemins décrochent avant que le serveur ait annoncé '
            'son identifiant : ne pas les casser',
      );
    });
  });
}
