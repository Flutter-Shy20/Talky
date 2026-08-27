import 'package:talky_flutter/core/services/call/call_history_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('curseur de pagination (A2)', () {
    test('aucun curseur pour la première page', () {
      expect(sendsCursor(null), isFalse);
    });

    test('un idCall à 0 est un curseur comme un autre', () {
      expect(
        sendsCursor(0),
        isTrue,
        reason: 'Call.fromJson défaute à 0 : le filtrer sur > 0 faisait '
            'redemander la première page indéfiniment',
      );
    });

    test('un curseur ordinaire est transmis', () {
      expect(sendsCursor(2047), isTrue);
      expect(sendsCursor(1), isTrue);
    });

    test('un curseur négatif est transmis aussi — le serveur tranche', () {
      expect(
        sendsCursor(-1),
        isTrue,
        reason: 'getCalls répond par une page vide sur un curseur inconnu, '
            'plutôt que de renvoyer la page 1',
      );
    });
  });

  group('exclusion des chargements (A3)', () {
    bool call({
      bool isLoadingMore = false,
      bool isLoading = false,
      bool isRefreshing = false,
      bool hasMore = true,
      bool hasCalls = true,
    }) =>
        canLoadMorePage(
          isLoadingMore: isLoadingMore,
          isLoading: isLoading,
          isRefreshing: isRefreshing,
          hasMore: hasMore,
          hasCalls: hasCalls,
        );

    test('cas nominal : on peut charger la suite', () {
      expect(call(), isTrue);
    });

    test('pas pendant un rafraîchissement', () {
      expect(
        call(isRefreshing: true),
        isFalse,
        reason: 'les deux écrivent _hasMore ; le plus lent écrasait la '
            'conclusion du plus rapide',
      );
    });

    test('pas pendant un chargement déjà en cours', () {
      expect(call(isLoadingMore: true), isFalse);
      expect(call(isLoading: true), isFalse);
    });

    test('pas quand l\'historique est épuisé', () {
      expect(call(hasMore: false), isFalse);
    });

    test('pas sans point de départ : le curseur vient du dernier appel', () {
      expect(call(hasCalls: false), isFalse);
    });
  });

  group('sens de l\'appel (A4)', () {
    test('un appel manqué reste manqué, quel que soit le sens', () {
      expect(
        callDirection(isMissed: true, isIncoming: true),
        CallDirection.missed,
      );
      expect(
        callDirection(isMissed: true, isIncoming: false),
        CallDirection.missed,
      );
    });

    test('un appel reçu et décroché est entrant', () {
      expect(
        callDirection(isMissed: false, isIncoming: true),
        CallDirection.incoming,
        reason: 'le journal affichait la flèche sortante pour tout appel '
            'non manqué — sa fonction première ne marchait pas',
      );
    });

    test('un appel passé est sortant', () {
      expect(
        callDirection(isMissed: false, isIncoming: false),
        CallDirection.outgoing,
      );
    });
  });
}
