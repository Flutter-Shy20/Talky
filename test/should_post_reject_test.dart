// Un salon de groupe n'est pas un appel à deux.
//
// Posté sur /calls/reject, il faisait retomber le serveur sur « le dernier
// appel entre ces deux comptes », qu'il passait à « Rejeté » — un appel abouti,
// parfois vieux de plusieurs jours, réécrit chez les deux correspondants.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  test('un identifiant d\'appel se poste', () {
    expect(shouldPostRejectToServer('4213'), isTrue);
    expect(shouldPostRejectToServer(' 4213 '), isTrue);
  });

  test('sans identifiant, on laisse le serveur trancher', () {
    expect(shouldPostRejectToServer(null), isTrue);
    expect(shouldPostRejectToServer(''), isTrue);
  });

  test('un salon de groupe ne se poste pas', () {
    expect(shouldPostRejectToServer('group_12_1712345678901'), isFalse);
  });

  test('une session de conférence ni une réunion non plus', () {
    expect(shouldPostRejectToServer('conf_88'), isFalse);
    expect(shouldPostRejectToServer('meeting_7'), isFalse);
  });
}
