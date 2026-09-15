// B9 — un appel sortant porte deux identifiants : celui fabriqué localement
// pour ouvrir la session CallKit, et celui du serveur, adopté au décrochage.
// Ces tests fixent qui répond à quoi.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  const kit = 'call_1724800000000';
  const serveur = 'srv-42';

  group('matchesCallIdentity', () {
    test('reconnaît l\'identifiant serveur', () {
      expect(
        matchesCallIdentity(
          candidate: serveur,
          currentCallId: serveur,
          callKitCallId: kit,
        ),
        isTrue,
      );
    });

    test('reconnaît aussi celui de CallKit après adoption du serveur', () {
      // Le cas de la régression : `_currentCallId` a basculé sur l'identifiant
      // serveur, et CallKit continue de parler du sien.
      expect(
        matchesCallIdentity(
          candidate: kit,
          currentCallId: serveur,
          callKitCallId: kit,
        ),
        isTrue,
      );
    });

    test('refuse un identifiant étranger', () {
      expect(
        matchesCallIdentity(
          candidate: 'srv-99',
          currentCallId: serveur,
          callKitCallId: kit,
        ),
        isFalse,
      );
    });

    test('refuse le vide et le nul', () {
      expect(
        matchesCallIdentity(candidate: null, currentCallId: serveur),
        isFalse,
      );
      expect(
        matchesCallIdentity(candidate: '', currentCallId: serveur),
        isFalse,
      );
      // Un appel inexistant ne se reconnaît dans rien.
      expect(
        matchesCallIdentity(candidate: kit, currentCallId: null, callKitCallId: null),
        isFalse,
      );
    });

    test('avant le décrochage les deux identifiants sont confondus', () {
      expect(
        matchesCallIdentity(
          candidate: kit,
          currentCallId: kit,
          callKitCallId: kit,
        ),
        isTrue,
      );
    });
  });

  group('matchesActiveOutgoingCall', () {
    for (final statut in ['outgoing', 'connecting', 'connected', 'reconnecting']) {
      test('$statut : la session CallKit est encore la nôtre', () {
        expect(
          matchesActiveOutgoingCall(
            candidate: kit,
            callStatusName: statut,
            currentCallId: serveur,
            callKitCallId: kit,
          ),
          isTrue,
        );
      });
    }

    for (final statut in ['idle', 'incoming', 'ended', 'joining']) {
      test('$statut : rien à préserver', () {
        expect(
          matchesActiveOutgoingCall(
            candidate: kit,
            callStatusName: statut,
            currentCallId: serveur,
            callKitCallId: kit,
          ),
          isFalse,
        );
      });
    }

    test('un autre appel, même en cours, ne compte pas', () {
      expect(
        matchesActiveOutgoingCall(
          candidate: 'call_1724899999999',
          callStatusName: 'connected',
          currentCallId: serveur,
          callKitCallId: kit,
        ),
        isFalse,
      );
    });
  });

  group('shouldAdoptServerCallId', () {
    test('adopte l\'identifiant serveur au décrochage', () {
      expect(
        shouldAdoptServerCallId(serverCallId: serveur, currentCallId: kit),
        isTrue,
      );
    });

    test('n\'adopte rien si le serveur n\'en donne pas', () {
      expect(shouldAdoptServerCallId(serverCallId: null, currentCallId: kit), isFalse);
      expect(shouldAdoptServerCallId(serverCallId: '', currentCallId: kit), isFalse);
      expect(shouldAdoptServerCallId(serverCallId: '   ', currentCallId: kit), isFalse);
    });

    test('ne se réadopte pas lui-même', () {
      expect(
        shouldAdoptServerCallId(serverCallId: serveur, currentCallId: serveur),
        isFalse,
      );
    });
  });

  group('sous quel identifiant l\'instantané sortant est enregistré', () {
    test('celui de CallKit, pas celui du serveur', () {
      // Les deux lecteurs de l\'instantané reçoivent l\'identifiant que porte
      // l\'entrée CallKit : c\'est le seul qui survive à un kill.
      expect(
        outgoingSnapshotIdentity(callKitCallId: kit, currentCallId: serveur),
        kit,
      );
    });

    test('avant le décrochage les deux sont le même', () {
      expect(
        outgoingSnapshotIdentity(callKitCallId: kit, currentCallId: kit),
        kit,
      );
    });

    test('sans session CallKit, on retombe sur l\'identifiant courant', () {
      // Le web n\'ouvre pas de session CallKit.
      expect(
        outgoingSnapshotIdentity(callKitCallId: null, currentCallId: serveur),
        serveur,
      );
      expect(
        outgoingSnapshotIdentity(callKitCallId: '  ', currentCallId: serveur),
        serveur,
      );
    });

    test('sans rien, rien à enregistrer', () {
      expect(outgoingSnapshotIdentity(), isNull);
      expect(
        outgoingSnapshotIdentity(callKitCallId: '', currentCallId: ''),
        isNull,
      );
    });
  });
}
