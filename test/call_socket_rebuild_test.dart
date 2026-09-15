// Pendant une reconnexion d'appel, un socket muet doit être reconstruit.
//
// Le TCP peut tomber sans que Socket.IO le constate avant 45 secondes
// (25 s de ping, 20 s de patience). `isSocketReady` répond `true`, les offres
// de reprise partent dans le vide, et l'appel se coupe seul au délai global.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

const seuil = Duration(seconds: 8);

bool decide({
  bool reconnexion = true,
  bool dejaFait = false,
  Duration? silence = const Duration(seconds: 20),
}) =>
    shouldRebuildSocketDuringReconnect(
      stillReconnecting: reconnexion,
      alreadyRebuilt: dejaFait,
      sinceLastSocketEvent: silence,
      silenceThreshold: seuil,
    );

void main() {
  test('socket muet pendant la reconnexion → on le reconstruit', () {
    expect(decide(), isTrue);
  });

  test('socket encore bavard → on n\'y touche pas', () {
    // Il livre des candidats ICE : c'est peut-être notre seule chance de reprise.
    expect(decide(silence: const Duration(seconds: 2)), isFalse);
  });

  test('le seuil est inclusif', () {
    expect(decide(silence: seuil), isTrue);
    expect(decide(silence: seuil - const Duration(milliseconds: 1)), isFalse);
  });

  test('une seule reconstruction par épisode', () {
    // Sinon la signalisation repartirait de zéro toutes les huit secondes et
    // aucune négociation n'aboutirait jamais.
    expect(decide(dejaFait: true), isFalse);
  });

  test('appel plus en reconnexion → rien à faire', () {
    expect(decide(reconnexion: false), isFalse);
  });

  test('aucun événement jamais reçu → rien à préserver', () {
    expect(decide(silence: null), isTrue);
    expect(decide(silence: null, dejaFait: true), isFalse);
  });
}
