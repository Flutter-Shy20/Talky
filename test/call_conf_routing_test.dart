import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_conf_routing.dart';
import 'package:talky_flutter/core/services/callkit_service.dart';

void main() {
  group('isConferenceCallIncoming', () {
    test('sessionKind conference', () {
      expect(
        isConferenceCallIncoming(sessionKind: 'conference', callId: '1'),
        isTrue,
      );
    });
    test('callId conf_ prefix', () {
      expect(
        isConferenceCallIncoming(callId: 'conf_123_1'),
        isTrue,
      );
    });
    test('roomId conf_ prefix', () {
      expect(
        isConferenceCallIncoming(callId: 'x', roomId: 'conf_9_1'),
        isTrue,
      );
    });
    test('1-1 classique', () {
      expect(
        isConferenceCallIncoming(callId: '42', roomId: null),
        isFalse,
      );
    });
  });

  group('IncomingCallAction.isConference', () {
    test('route acceptConferenceInvite', () {
      final a = IncomingCallAction(
        callId: 'conf_1_1',
        callerId: '2',
        callerName: 'A',
        callerPhoto: null,
        isVideo: false,
        roomId: 'conf_1_1',
        sessionKind: 'conference',
        mode: 'transfer',
        action: IncomingCallActionType.accept,
      );
      expect(a.isConference, isTrue);
      expect(a.mode, 'transfer');
    });
    test('1-1 pas conférence', () {
      final a = IncomingCallAction(
        callId: '99',
        callerId: '2',
        callerName: 'A',
        callerPhoto: null,
        isVideo: false,
        roomId: null,
        action: IncomingCallActionType.accept,
      );
      expect(a.isConference, isFalse);
    });
  });

  group('shouldMergeConfInvite', () {
    test('même session incoming → merge', () {
      expect(
        shouldMergeConfInvite(
          callStatusName: 'incoming',
          confSessionId: 'conf_1',
          currentCallId: 'conf_1',
          incomingSessionId: 'conf_1',
        ),
        isTrue,
      );
    });
    test('autre status → pas merge', () {
      expect(
        shouldMergeConfInvite(
          callStatusName: 'connected',
          confSessionId: 'conf_1',
          currentCallId: 'conf_1',
          incomingSessionId: 'conf_1',
        ),
        isFalse,
      );
    });
    test('autre session → pas merge', () {
      expect(
        shouldMergeConfInvite(
          callStatusName: 'incoming',
          confSessionId: 'conf_1',
          currentCallId: 'conf_1',
          incomingSessionId: 'conf_2',
        ),
        isFalse,
      );
    });
  });

  group('canLocalEmitConfReady', () {
    test('B restant peut émettre vers C', () {
      expect(
        canLocalEmitConfReady(
          confMode: 'transfer',
          isTransferInitiator: false,
          isConfInvitee: false,
          peerId: '3',
          localUserId: 2,
          transferTargetId: '3',
        ),
        isTrue,
      );
    });
    test('initiateur n\'émet pas', () {
      expect(
        canLocalEmitConfReady(
          confMode: 'transfer',
          isTransferInitiator: true,
          isConfInvitee: false,
          peerId: '3',
          localUserId: 1,
          transferTargetId: '3',
        ),
        isFalse,
      );
    });
    test('C invité n\'émet pas', () {
      expect(
        canLocalEmitConfReady(
          confMode: 'transfer',
          isTransferInitiator: false,
          isConfInvitee: true,
          peerId: '1',
          localUserId: 3,
          transferTargetId: '3',
        ),
        isFalse,
      );
    });
    test('mode join n\'émet pas', () {
      expect(
        canLocalEmitConfReady(
          confMode: 'join',
          isTransferInitiator: false,
          isConfInvitee: false,
          peerId: '3',
          localUserId: 2,
          transferTargetId: '3',
        ),
        isFalse,
      );
    });
    test('peer ≠ cible transfert → pas de ready', () {
      expect(
        canLocalEmitConfReady(
          confMode: 'transfer',
          isTransferInitiator: false,
          isConfInvitee: false,
          peerId: '1',
          localUserId: 2,
          transferTargetId: '3',
        ),
        isFalse,
      );
    });
    test('sans transferTargetId → pas de ready', () {
      expect(
        canLocalEmitConfReady(
          confMode: 'transfer',
          isTransferInitiator: false,
          isConfInvitee: false,
          peerId: '3',
          localUserId: 2,
        ),
        isFalse,
      );
    });
  });

  group('confJoinFlushDecision', () {
    test('emit quand prêt', () {
      expect(
        confJoinFlushDecision(
          pendingSessionId: 'conf_1',
          confSessionId: 'conf_1',
          isTerminal: false,
          callStatusName: 'joining',
          socketReady: true,
        ),
        ConfQueueFlushResult.emit,
      );
    });
    test('keep si socket pas prêt', () {
      expect(
        confJoinFlushDecision(
          pendingSessionId: 'conf_1',
          confSessionId: 'conf_1',
          isTerminal: false,
          callStatusName: 'connected',
          socketReady: false,
        ),
        ConfQueueFlushResult.keep,
      );
    });
    test('drop si terminal', () {
      expect(
        confJoinFlushDecision(
          pendingSessionId: 'conf_1',
          confSessionId: 'conf_1',
          isTerminal: true,
          callStatusName: 'joining',
          socketReady: true,
        ),
        ConfQueueFlushResult.drop,
      );
    });
  });

  group('confReadyFlushDecision + clé unique', () {
    test('clé idempotente', () {
      expect(confReadyKey('conf_1', '3'), 'conf_1|3');
    });
    test('emit unique path', () {
      expect(
        confReadyFlushDecision(
          keySessionId: 'conf_1',
          confSessionId: 'conf_1',
          isTerminal: false,
          confMode: 'transfer',
          isTransferInitiator: false,
          callStatusName: 'connected',
          socketReady: true,
        ),
        ConfQueueFlushResult.emit,
      );
    });
    test('drop si initiateur', () {
      expect(
        confReadyFlushDecision(
          keySessionId: 'conf_1',
          confSessionId: 'conf_1',
          isTerminal: false,
          confMode: 'transfer',
          isTransferInitiator: true,
          callStatusName: 'connected',
          socketReady: true,
        ),
        ConfQueueFlushResult.drop,
      );
    });
  });

  group('refus conférence', () {
    test('decline CallKit conf → call_conf_reject (contrat event)', () {
      // Le chemin CallKit decline utilise action.isConference pour router
      // vers call_conf_reject plutôt que reject_call.
      final decline = IncomingCallAction(
        callId: 'conf_5_1',
        callerId: '1',
        callerName: 'A',
        callerPhoto: null,
        isVideo: false,
        roomId: 'conf_5_1',
        sessionKind: 'conference',
        mode: 'join',
        action: IncomingCallActionType.decline,
      );
      expect(decline.isConference, isTrue);
      expect(decline.action, IncomingCallActionType.decline);
    });
  });

  group('originLinkRole — bascule à trois', () {
    test('premier ajout : la connexion 1-à-1 est versée dans le maillage', () {
      expect(
        originLinkRole(meshLinkExists: false, meshLinkIsOrigin: false),
        OriginLinkRole.verser,
      );
    });
    test("rebascule, l'invité était parti : le lien d'origine reste surveillé", () {
      expect(
        originLinkRole(meshLinkExists: true, meshLinkIsOrigin: true),
        OriginLinkRole.surveiller,
      );
    });
    test(
      'rebascule après un transfert : le lien vivant est maillé, '
      "la connexion d'origine n'y touche pas",
      () {
        expect(
          originLinkRole(meshLinkExists: true, meshLinkIsOrigin: false),
          OriginLinkRole.ignorer,
        );
      },
    );
  });

  group('meshSignalRoomId', () {
    test('en grille : la salle affichée', () {
      expect(meshSignalRoomId('conf_1_1', 'conf_1_1'), 'conf_1_1');
    });
    test('retombé à deux dans une session : la session, pas rien', () {
      expect(meshSignalRoomId(null, 'conf_1_1'), 'conf_1_1');
    });
    test('appel de groupe ordinaire : sa salle', () {
      expect(meshSignalRoomId('grp_9', null), 'grp_9');
    });
  });

  group('addRejectedResetsRound', () {
    test('refus sans invitation en vol : le tour local est remis à zéro', () {
      expect(addRejectedResetsRound(hasPendingInvitee: false), isTrue);
    });
    test("refus reçu après l'invitation du gagnant : le tour du gagnant tient", () {
      expect(addRejectedResetsRound(hasPendingInvitee: true), isFalse);
    });
  });

  group('canAddToCall — droit rendu au retour à deux', () {
    bool droit({
      String status = 'connected',
      bool session = false,
      bool grille = false,
      bool invitation = false,
      bool correspondant = true,
      bool reunion = false,
    }) =>
        canAddToCall(
          callStatusName: status,
          hasConfSession: session,
          showsGroupRoom: grille,
          hasPendingInvitee: invitation,
          hasRemoteUser: correspondant,
          meetingActive: reunion,
        );

    test('appel à deux ordinaire : proposé', () {
      expect(droit(), isTrue);
    });
    test('retombé à deux dans une session : proposé à nouveau', () {
      expect(droit(session: true), isTrue);
    });
    test('grille à trois affichée : absent', () {
      expect(droit(session: true, grille: true), isFalse);
    });
    test('invitation en vol : absent', () {
      expect(droit(session: true, invitation: true), isFalse);
    });
    test('pas encore connecté : absent', () {
      expect(droit(status: 'connecting'), isFalse);
    });
    test('en réunion : absent', () {
      expect(droit(reunion: true), isFalse);
    });
  });

  group('confFailedKeepsSession', () {
    test('le serveur garde la session', () {
      expect(confFailedKeepsSession({'keepSession': true}), isTrue);
      expect(confFailedKeepsSession({'keepSession': 'true'}), isTrue);
    });
    test('première invitation soldée : la session disparaît', () {
      expect(confFailedKeepsSession({'keepSession': false}), isFalse);
    });
    test('serveur plus ancien, sans drapeau : comportement d\'avant', () {
      expect(confFailedKeepsSession({}), isFalse);
    });
  });

  group("identifiant d'invitation", () {
    test("second tour : l'invitation a son propre identifiant", () {
      expect(
        conferenceInviteId({'sessionId': 'conf_7_1', 'inviteId': 'conf_7_1_r2'}),
        'conf_7_1_r2',
      );
    });
    test('serveur plus ancien : aucun, on retombe sur la session', () {
      expect(conferenceInviteId({'sessionId': 'conf_7_1'}), isNull);
      expect(conferenceInviteId({'sessionId': 'conf_7_1', 'inviteId': ''}), isNull);
    });
    test('call_ended adressé à un invité : son invitation', () {
      expect(
        endedCallId({'callId': 'conf_7_1', 'inviteId': 'conf_7_1_r2'}),
        'conf_7_1_r2',
      );
    });
    test('call_ended ordinaire : son callId', () {
      expect(endedCallId({'callId': '42'}), '42');
      expect(endedCallId({}), isNull);
    });
  });
}
