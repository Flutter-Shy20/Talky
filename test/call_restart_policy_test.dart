import 'package:talky_flutter/core/services/call/call_restart_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 8, 27, 12, 0, 0);
  const window = Duration(seconds: 12);

  group('espacement des offres de reprise', () {
    test('aucune offre encore émise → on peut émettre', () {
      expect(
        canEmitRestartOffer(lastOfferAt: null, now: t0, window: window),
        isTrue,
      );
    });

    test('une offre vient de partir → on attend', () {
      expect(
        canEmitRestartOffer(
          lastOfferAt: t0,
          now: t0.add(const Duration(milliseconds: 40)),
          window: window,
        ),
        isFalse,
        reason: 'deux call_resume d\'affilée ne doivent pas faire deux offres',
      );
    });

    test('offre restée sans réponse au-delà de la fenêtre → on réémet', () {
      expect(
        canEmitRestartOffer(
          lastOfferAt: t0,
          now: t0.add(const Duration(seconds: 12)),
          window: window,
        ),
        isTrue,
      );
      expect(
        canEmitRestartOffer(
          lastOfferAt: t0,
          now: t0.add(const Duration(seconds: 30)),
          window: window,
        ),
        isTrue,
      );
    });

    test('juste avant la fenêtre → toujours pas', () {
      expect(
        canEmitRestartOffer(
          lastOfferAt: t0,
          now: t0.add(const Duration(seconds: 11, milliseconds: 999)),
          window: window,
        ),
        isFalse,
      );
    });
  });

  group('offres de reprise périmées', () {
    test('génération antérieure → ignorée', () {
      expect(
        isStaleRejoinOffer(offerGeneration: 2, localGeneration: 3),
        isTrue,
      );
    });

    test('même génération → acceptée', () {
      expect(
        isStaleRejoinOffer(offerGeneration: 3, localGeneration: 3),
        isFalse,
      );
    });

    test('génération plus récente → acceptée', () {
      expect(
        isStaleRejoinOffer(offerGeneration: 4, localGeneration: 3),
        isFalse,
      );
    });

    test('sans génération → acceptée (client sans compteur)', () {
      expect(
        isStaleRejoinOffer(offerGeneration: null, localGeneration: 3),
        isFalse,
      );
    });

    test('première négociation → acceptée', () {
      expect(
        isStaleRejoinOffer(offerGeneration: 0, localGeneration: 0),
        isFalse,
      );
    });
  });
}
