// Une notification expirée n'est pas un refus.
//
// Les 40 secondes de la notification sont posées délibérément avant les 45
// secondes du serveur. Rapporter l'expiration comme un refus faisait donc
// toujours gagner le refus : un appel qu'on n'a pas entendu s'inscrivait
// « Rejeté » chez les deux correspondants.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  test('un refus explicite se signale', () {
    expect(reportForTerminalAction('decline'), TerminalCallReport.refus);
  });

  test('une expiration ne signale rien — le minuteur serveur tranche', () {
    expect(reportForTerminalAction('timeout'), TerminalCallReport.rien);
  });

  test('un retrait système ne signale rien non plus', () {
    // Un autre appareil peut encore sonner, ou avoir déjà décroché.
    expect(reportForTerminalAction('ended'), TerminalCallReport.rien);
  });

  test('une action inconnue ne signale rien', () {
    expect(reportForTerminalAction('accept'), TerminalCallReport.rien);
    expect(reportForTerminalAction(''), TerminalCallReport.rien);
  });
}
