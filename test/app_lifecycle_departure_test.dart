// Le retour au premier plan traverse `hidden` avant `resumed`. L'accueil le
// prenait pour un départ en arrière-plan et rebasculait l'appel entrant vers
// CallKit au moment où l'utilisateur venait de décrocher : le décrochage était
// perdu, l'écran se fermait, et l'appel était refusé au correspondant.

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  group('départ en arrière-plan (cycle de vie)', () {
    test('paused et detached sont des départs', () {
      for (final etat in ['paused', 'detached']) {
        expect(
          isBackgroundDeparture(stateName: etat, previousStateName: 'resumed'),
          isTrue,
          reason: etat,
        );
      }
    });

    test('un départ reste un départ quel que soit l\'état précédent', () {
      for (final precedent in ['resumed', 'inactive', 'hidden', null]) {
        expect(
          isBackgroundDeparture(
            stateName: 'paused',
            previousStateName: precedent,
          ),
          isTrue,
          reason: 'précédent=$precedent',
        );
      }
    });

    test('hidden qui descend de resumed ou d\'inactive est un départ', () {
      for (final precedent in ['resumed', 'inactive']) {
        expect(
          isBackgroundDeparture(
            stateName: 'hidden',
            previousStateName: precedent,
          ),
          isTrue,
          reason: 'précédent=$precedent',
        );
      }
    });

    test('hidden qui remonte de paused n\'est pas un départ', () {
      expect(
        isBackgroundDeparture(stateName: 'hidden', previousStateName: 'paused'),
        isFalse,
        reason: 'paused → hidden → inactive → resumed est le chemin du RETOUR : '
            'le prendre pour un départ rebascule l\'appel entrant vers CallKit '
            'juste après le décrochage, et l\'appel est perdu',
      );
    });

    test('hidden sans état précédent connu reste un départ', () {
      expect(
        isBackgroundDeparture(stateName: 'hidden', previousStateName: null),
        isTrue,
        reason: 'un retour vient toujours de paused, donc un hidden dont on '
            'ignore la provenance est un départ : on garde le comportement '
            'd\'avant là où il était juste',
      );
    });

    test('inactive n\'est jamais un départ', () {
      for (final precedent in ['resumed', 'paused', 'hidden', null]) {
        expect(
          isBackgroundDeparture(
            stateName: 'inactive',
            previousStateName: precedent,
          ),
          isFalse,
          reason: 'précédent=$precedent',
        );
      }
    });

    test('resumed n\'est jamais un départ', () {
      for (final precedent in ['paused', 'hidden', 'inactive', null]) {
        expect(
          isBackgroundDeparture(
            stateName: 'resumed',
            previousStateName: precedent,
          ),
          isFalse,
          reason: 'précédent=$precedent',
        );
      }
    });
  });
}
