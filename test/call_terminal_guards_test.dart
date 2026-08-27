import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('call_ended ordinaire (B3)', () {
    test('termine l\'appel qu\'il désigne', () {
      expect(
        endsCurrentCall(eventCallId: '2047', currentCallId: '2047'),
        isTrue,
      );
    });

    test('ignore un événement en retard, adressé à un autre appel', () {
      expect(
        endsCurrentCall(eventCallId: '2041', currentCallId: '2047'),
        isFalse,
        reason: 'le serveur émet call_ended depuis treize endroits',
      );
    });

    test('reconnaît la session à trois et la salle de groupe', () {
      expect(
        endsCurrentCall(
          eventCallId: 'conf_2047_1',
          currentCallId: '2047',
          confSessionId: 'conf_2047_1',
        ),
        isTrue,
      );
      expect(
        endsCurrentCall(
          eventCallId: 'room_9',
          currentCallId: '2047',
          groupRoomId: 'room_9',
        ),
        isTrue,
      );
    });

    test('sans identifiant, on applique — comportement historique', () {
      expect(endsCurrentCall(eventCallId: null, currentCallId: '2047'), isTrue);
      expect(endsCurrentCall(eventCallId: '', currentCallId: '2047'), isTrue);
    });

    test('sans appel courant, un événement identifié ne termine rien', () {
      expect(endsCurrentCall(eventCallId: '2041', currentCallId: null), isFalse);
    });
  });

  group('événements terminaux d\'un sortant (B4)', () {
    test('acceptés pendant qu\'on passe l\'appel', () {
      for (final status in ['outgoing', 'connecting']) {
        expect(
          acceptsOutgoingTerminalEvent(
            callStatusName: status,
            eventCallId: '2047',
            currentCallId: '2047',
          ),
          isTrue,
          reason: 'statut $status',
        );
      }
    });

    test('refusés une fois l\'appel établi ou raccroché', () {
      for (final status in ['connected', 'reconnecting', 'idle', 'incoming', 'joining']) {
        expect(
          acceptsOutgoingTerminalEvent(
            callStatusName: status,
            eventCallId: '2047',
            currentCallId: '2047',
          ),
          isFalse,
          reason: 'statut $status — même garde que call_busy / call_no_answer',
        );
      }
    });

    test('refusés quand ils désignent un autre appel', () {
      expect(
        acceptsOutgoingTerminalEvent(
          callStatusName: 'outgoing',
          eventCallId: '2041',
          currentCallId: '2047',
        ),
        isFalse,
        reason: 'un refus tardif ne doit pas tuer l\'appel suivant',
      );
    });

    test('sans identifiant, le statut suffit', () {
      expect(
        acceptsOutgoingTerminalEvent(
          callStatusName: 'outgoing',
          eventCallId: null,
          currentCallId: '2047',
        ),
        isTrue,
        reason: 'call_failed n\'en porte pas toujours',
      );
    });

    test('appel sortant pas encore identifié : on accepte', () {
      expect(
        acceptsOutgoingTerminalEvent(
          callStatusName: 'outgoing',
          eventCallId: '2047',
          currentCallId: null,
        ),
        isTrue,
      );
    });
  });

  group('group_call_ended (B5)', () {
    test('démonte la salle où l\'on se trouve', () {
      expect(
        endsGroupCall(
          groupRoomId: 'room_9',
          eventRoomId: 'room_9',
          callStatusName: 'connected',
        ),
        isTrue,
      );
    });

    test('ignore un événement de la salle précédente', () {
      expect(
        endsGroupCall(
          groupRoomId: 'room_9',
          eventRoomId: 'room_8',
          callStatusName: 'connected',
        ),
        isFalse,
        reason: 'sinon le média de l\'appel en cours est détruit',
      );
    });

    test('sans salle courante, rien à démonter', () {
      expect(
        endsGroupCall(
          groupRoomId: null,
          eventRoomId: 'room_9',
          callStatusName: 'connected',
        ),
        isFalse,
      );
    });

    test('appel déjà terminé : sans effet', () {
      for (final status in ['idle', 'ended']) {
        expect(
          endsGroupCall(
            groupRoomId: 'room_9',
            eventRoomId: 'room_9',
            callStatusName: status,
          ),
          isFalse,
          reason: 'statut $status',
        );
      }
    });

    test('payload vide : on fait confiance à la salle courante', () {
      expect(
        endsGroupCall(
          groupRoomId: 'room_9',
          eventRoomId: null,
          callStatusName: 'connected',
        ),
        isTrue,
        reason: 'le serveur émet {} aujourd\'hui',
      );
    });
  });

  group('rôle de restart après reprise (B2)', () {
    test('le rôle du serveur fait autorité', () {
      expect(resolveOutgoingCaller(serverRole: 'caller', current: false), isTrue);
      expect(
        resolveOutgoingCaller(serverRole: 'callee', current: true),
        isFalse,
        reason: 'c\'est le cas qui provoquait le glare offer/offer',
      );
    });

    test('sans rôle transmis, on conserve ce qu\'on savait', () {
      expect(resolveOutgoingCaller(serverRole: null, current: true), isTrue);
      expect(resolveOutgoingCaller(serverRole: null, current: false), isFalse);
      expect(resolveOutgoingCaller(serverRole: '', current: false), isFalse);
    });

    test('un rôle inconnu ne renverse pas la décision locale', () {
      expect(resolveOutgoingCaller(serverRole: 'peer', current: true), isTrue);
    });
  });
}
