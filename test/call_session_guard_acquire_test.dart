// Une acquisition qui ne configure rien ne doit pas compter.
//
// Le compteur de références était incrémenté dans les trois cas, y compris
// quand `acquire` sortait aussitôt sans avoir touché `_callId` ni le mode. Le
// `release()` d'en face ne redescendait alors jamais à zéro : verrou de veille,
// capteur de proximité, service au premier plan, focus audio et entrée CallKit
// restaient tenus pour de bon.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call_session_guard.dart';

void main() {
  test('session libre → acquisition fraîche', () {
    expect(
      classerAcquisition(refCount: 0, tenuPar: null, callId: 'a'),
      SessionAcquisition.fraiche,
    );
  });

  test('même appel → imbrication légitime, on compte', () {
    // `answerCall` après `acceptIncomingCallFromPush`, par exemple.
    expect(
      classerAcquisition(refCount: 1, tenuPar: 'a', callId: 'a'),
      SessionAcquisition.imbriquee,
    );
  });

  test('autre appel → conflit', () {
    // Rejoindre une réunion pendant un appel : ni le salon de réunion ni
    // `meeting_service` n'ont de garde.
    expect(
      classerAcquisition(refCount: 1, tenuPar: 'appel-7', callId: 'meeting_42'),
      SessionAcquisition.conflit,
    );
  });

  test('un compteur non nul sans détenteur connu reste un conflit', () {
    // On ne sait pas à qui est la session : la donner serait pire que la refuser.
    expect(
      classerAcquisition(refCount: 2, tenuPar: null, callId: 'a'),
      SessionAcquisition.conflit,
    );
  });
}
