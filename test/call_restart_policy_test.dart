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

  group('appariement du snapshot sortant (B8)', () {
    const client = 'client_1787849272495';
    const peer = 98;
    final started = DateTime(2026, 8, 27, 12).millisecondsSinceEpoch;

    bool match({
      String? serverId,
      String eventCallId = '2047',
      int eventPeer = peer,
      int ageMs = 0,
    }) =>
        snapshotMatchesResume(
          snapServerCallId: serverId,
          snapClientCallId: client,
          snapPeerId: peer,
          snapStartedAtMs: started,
          eventCallId: eventCallId,
          eventPeerId: eventPeer,
          nowMs: started + ageMs,
        );

    test('même identifiant serveur : c\'est le bon appel', () {
      expect(match(serverId: '2047'), isTrue);
    });

    test('l\'identifiant client vaut aussi', () {
      expect(match(serverId: '2047', eventCallId: client), isTrue);
    });

    test('un autre interlocuteur ne correspond jamais', () {
      expect(match(serverId: '2047', eventPeer: 77), isFalse);
    });

    test('un snapshot qui connaît son identifiant refuse les autres', () {
      expect(
        match(serverId: '2041'),
        isFalse,
        reason: 'c\'est un appel précédent vers la même personne',
      );
    });

    test('un snapshot muet et récent reste accepté', () {
      expect(
        match(serverId: null, ageMs: 30 * 1000),
        isTrue,
        reason: 'un sortant tué avant call_answered n\'a jamais connu son '
            'identifiant serveur',
      );
      expect(match(serverId: '', ageMs: 30 * 1000), isTrue);
    });

    test('passé la fenêtre, le joker ne joue plus', () {
      expect(
        match(serverId: null, ageMs: 3 * 60 * 1000),
        isFalse,
        reason: 'le snapshot vit deux heures, la preuve de fin deux minutes : '
            'au-delà, plus rien ne dit si cet appel est terminé',
      );
    });

    test('un snapshot venu du futur est refusé', () {
      expect(match(serverId: null, ageMs: -1000), isFalse);
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

  group('rejoin de la salle de groupe après reconnexion', () {
    test('en communication : on redemande sa place', () {
      expect(
        shouldRejoinGroupRoom(
          groupRoomId: 'room_7',
          callStatusName: 'connected',
          isConference: false,
        ),
        isTrue,
      );
    });

    test('pendant la reconnexion aussi — c\'est même le cas nominal', () {
      expect(
        shouldRejoinGroupRoom(
          groupRoomId: 'room_7',
          callStatusName: 'reconnecting',
          isConference: false,
        ),
        isTrue,
      );
    });

    test('et pendant l\'entrée dans la salle', () {
      expect(
        shouldRejoinGroupRoom(
          groupRoomId: 'room_7',
          callStatusName: 'joining',
          isConference: false,
        ),
        isTrue,
      );
    });

    test('hors appel de groupe : rien à rejoindre', () {
      expect(
        shouldRejoinGroupRoom(
          groupRoomId: null,
          callStatusName: 'connected',
          isConference: false,
        ),
        isFalse,
      );
      expect(
        shouldRejoinGroupRoom(
          groupRoomId: '',
          callStatusName: 'connected',
          isConference: false,
        ),
        isFalse,
      );
    });

    test('session à trois : ses participants ne sont pas dans la salle', () {
      // Tout leur est adressé par appareil ; un join_group_call les inscrirait
      // dans une salle de groupe qui n'a rien à voir avec leur session.
      expect(
        shouldRejoinGroupRoom(
          groupRoomId: 'session_9',
          callStatusName: 'connected',
          isConference: true,
        ),
        isFalse,
      );
    });

    test('raccrochage en cours : ne pas se réinviter', () {
      expect(
        shouldRejoinGroupRoom(
          groupRoomId: 'room_7',
          callStatusName: 'connected',
          isConference: false,
          isEndingCall: true,
        ),
        isFalse,
      );
    });

    for (final statut in ['idle', 'ended', 'incoming', 'outgoing']) {
      test('$statut : aucune salle à reprendre', () {
        expect(
          shouldRejoinGroupRoom(
            groupRoomId: 'room_7',
            callStatusName: statut,
            isConference: false,
          ),
          isFalse,
        );
      });
    }
  });
}
