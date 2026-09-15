// La messagerie ne doit pas démonter le socket de signalisation.
//
// `flushOutbox` tourne sur une minuterie de 75 secondes, sans rapport avec les
// appels. S'il traîne un message sans accusé depuis plus de 25 secondes, il
// appelait `forceReconnect` — qui détruit l'instance socket et la recrée. En
// pleine conversation, c'est l'appel qu'on coupe.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/chat/message_outbox.dart';

void main() {
  test('un message en souffrance justifie bien le reconnect', () {
    expect(
      shouldForceReconnectForOutbox(
        hasStalePending: true,
        callSessionActive: false,
      ),
      isTrue,
    );
  });

  test('mais jamais pendant un appel', () {
    // C'est tout l'objet du correctif : le socket démonté ici est celui de la
    // signalisation. Le serveur verrait le téléphone disparaître.
    expect(
      shouldForceReconnectForOutbox(
        hasStalePending: true,
        callSessionActive: true,
      ),
      isFalse,
    );
  });

  test('sans message en souffrance, rien à reconstruire', () {
    expect(
      shouldForceReconnectForOutbox(
        hasStalePending: false,
        callSessionActive: false,
      ),
      isFalse,
    );
    expect(
      shouldForceReconnectForOutbox(
        hasStalePending: false,
        callSessionActive: true,
      ),
      isFalse,
    );
  });
}
