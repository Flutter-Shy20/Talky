// Une invitation de groupe sans salon rendait l'appareil sourd.
//
// Le statut passait à « entrant », la revendication de présentation était
// refusée faute d'identifiant, aucune interface ne s'ouvrait, aucun filet
// temporel n'était armé — et tous les points d'entrée refusent un entrant tant
// que le statut n'est pas `idle`. Plus aucun appel ne pouvait arriver.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  test('un salon nommé est présentable', () {
    expect(groupInviteIsPresentable('room_42'), isTrue);
  });

  test('absent, vide ou blanc : on refuse d\'entrer dans l\'état', () {
    for (final salon in [null, '', '   ']) {
      expect(groupInviteIsPresentable(salon), isFalse, reason: '«$salon»');
    }
  });
}
