// Que faire d'un `auth:error` ?
//
// Le handler ne réagissait qu'à TOKEN_EXPIRED : pour tout autre échec il notait
// « non authentifié » et rendait la main, socket TCP bien vivant. Or c'est
// précisément l'état dont rien ne sort — ensureSocketReady ne recrée l'instance
// que si elle est déconnectée, et le chien de garde exige des messages en
// attente, qu'un appel en cours ne produit pas.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/api/socket_auth_recovery.dart';

void main() {
  SocketAuthRecovery decide({
    String? code,
    bool refresh = true,
    int attempts = 0,
  }) =>
      socketAuthRecovery(
        code: code,
        hasRefreshToken: refresh,
        attempts: attempts,
      );

  group('jeton périmé', () {
    test('on rafraîchit quand on a de quoi', () {
      expect(decide(code: 'TOKEN_EXPIRED'), SocketAuthRecovery.refreshToken);
    });

    test('sans jeton de rafraîchissement, il n\'y a rien à tenter', () {
      expect(
        decide(code: 'TOKEN_EXPIRED', refresh: false),
        SocketAuthRecovery.giveUp,
      );
    });
  });

  group('refus définitifs', () {
    for (final code in ['TOKEN_REQUIRED', 'TOKEN_INVALID', 'AUTH_REJECTED', 'DEVICE_REVOKED']) {
      test('$code : réessayer ne ferait que marteler le serveur', () {
        expect(decide(code: code), SocketAuthRecovery.giveUp);
      });
    }

    test('la casse ne change rien', () {
      expect(decide(code: 'auth_rejected'), SocketAuthRecovery.giveUp);
    });
  });

  group('échecs passagers', () {
    test('AUTH_INTERNAL : le serveur dit lui-même que c\'est passager', () {
      // C'est le catch global du serveur, qui enveloppe une requête vers un
      // MySQL distant : pool saturé, hoquet réseau, timeout.
      expect(decide(code: 'AUTH_INTERNAL'), SocketAuthRecovery.retryLater);
    });

    test('un code absent vaut passager, délibérément', () {
      // C'est ce qu'émettait le serveur avant qu'on ne nomme les codes : rester
      // bloqué pour toujours coûte plus cher qu'une tentative inutile bornée.
      expect(decide(code: null), SocketAuthRecovery.retryLater);
      expect(decide(code: ''), SocketAuthRecovery.retryLater);
      expect(decide(code: 'QUELQUE_CHOSE_DE_NOUVEAU'), SocketAuthRecovery.retryLater);
    });

    test('mais les tentatives sont bornées', () {
      expect(decide(code: 'AUTH_INTERNAL', attempts: 2), SocketAuthRecovery.retryLater);
      expect(decide(code: 'AUTH_INTERNAL', attempts: 3), SocketAuthRecovery.giveUp);
      expect(decide(code: 'AUTH_INTERNAL', attempts: 99), SocketAuthRecovery.giveUp);
    });

    test('un jeton périmé reste rafraîchissable quel que soit le compteur', () {
      // Le rafraîchissement n'est pas une tentative en aveugle : il répare une
      // cause connue, et son propre échec repassera par ici.
      expect(
        decide(code: 'TOKEN_EXPIRED', attempts: 99),
        SocketAuthRecovery.refreshToken,
      );
    });
  });

  group('recul entre deux tentatives', () {
    test('croît, puis se stabilise', () {
      final d = [0, 1, 2, 3, 4].map(socketAuthRetryDelay).map((x) => x.inSeconds).toList();
      expect(d[0], 2);
      expect(d[1], greaterThan(d[0]));
      expect(d[2], greaterThan(d[1]));
      expect(d.last, lessThanOrEqualTo(16), reason: 'borné : on ne martèle pas');
    });

    test('jamais moins de deux secondes', () {
      expect(socketAuthRetryDelay(-5).inSeconds, greaterThanOrEqualTo(2));
    });
  });
}
