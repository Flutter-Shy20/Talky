// Un entrant de groupe n'a pas de callId — seulement un salon.
//
// Tout code qui vise l'entrant par son seul `callId` sort à vide pour un
// groupe. C'est ce qui laissait l'entrée CallKit en place pendant que la
// sonnerie Flutter démarrait : deux sonneries, et personne pour le dire.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  test('un appel à deux se désigne par son callId', () {
    expect(incomingPresentationId(callId: 'c-7'), 'c-7');
  });

  test('une invitation de groupe se désigne par son salon', () {
    expect(incomingPresentationId(groupRoomId: 'salon-3'), 'salon-3');
  });

  test('le callId prime quand les deux sont là', () {
    // Après `joinGroupCall`, les deux existent : c'est l'appel qui compte.
    expect(
      incomingPresentationId(callId: 'c-7', groupRoomId: 'salon-3'),
      'c-7',
    );
  });

  test('les chaînes vides ou blanches ne désignent rien', () {
    expect(incomingPresentationId(callId: '', groupRoomId: 'salon-3'),
        'salon-3');
    expect(incomingPresentationId(callId: '  ', groupRoomId: '  '), isNull);
    expect(incomingPresentationId(), isNull);
  });
}
