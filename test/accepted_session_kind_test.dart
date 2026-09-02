// Décrocher depuis une notification : qu'est-ce qu'on établit au juste ?
//
// La conférence était traitée, et tout le reste tombait dans la queue du 1-à-1 :
// armer l'auto-réponse, attendre une offre WebRTC. Un appel de groupe n'en
// produit aucune. Il restait donc « entrant » jusqu'au refus du filet de
// 55 secondes.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_conf_routing.dart';

void main() {
  test('sans salon, c\'est un appel à deux', () {
    expect(
      acceptedSessionKind(isConference: false),
      AcceptedSessionKind.unAUn,
    );
    expect(
      acceptedSessionKind(isConference: false, roomId: '  '),
      AcceptedSessionKind.unAUn,
    );
  });

  test('un salon sans conférence, c\'est un groupe', () {
    expect(
      acceptedSessionKind(isConference: false, roomId: 'salon-3'),
      AcceptedSessionKind.groupe,
    );
  });

  test('la conférence prime sur le salon', () {
    // Une session à trois porte son sessionId dans roomId : sans cette
    // priorité, elle serait prise pour un appel de groupe et rejoindrait
    // un salon qui n'existe pas.
    expect(
      acceptedSessionKind(isConference: true, roomId: 'conf_42'),
      AcceptedSessionKind.conference,
    );
    expect(
      acceptedSessionKind(isConference: true),
      AcceptedSessionKind.conference,
    );
  });
}
