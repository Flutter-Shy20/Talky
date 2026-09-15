// L'état de cycle de vie inconnu ne doit pas passer pour un premier plan.
//
// `WidgetsBinding.instance.lifecycleState` est `null` tant qu'aucun événement
// n'est arrivé — le cas d'un réveil par push derrière l'écran verrouillé. Le
// traiter comme un premier plan faisait revendiquer la présentation Flutter et
// lancer la sonnerie Dart pendant que CallKit sonnait nativement.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  test('resumed est le seul premier plan', () {
    expect(appIsForeground('resumed'), isTrue);
  });

  test('inconnu au démarrage → arrière-plan, donc CallKit présente', () {
    expect(appIsForeground(null), isFalse);
  });

  test('les autres états sont des arrière-plans', () {
    for (final etat in ['inactive', 'paused', 'detached', 'hidden']) {
      expect(appIsForeground(etat), isFalse, reason: etat);
    }
  });
}
